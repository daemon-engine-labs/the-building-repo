#!/usr/bin/env bash
# Install the arena runners + egress wall as launchd LaunchAgents (durable supervision — replaces
# nohup loops). Idempotent: safe to re-run. Ordering is deliberate and BOOTOUT-FIRST:
#
#   1. bootout ALL agents and WAIT for them to disappear — so KeepAlive cannot resurrect a runner
#      mid-install (the race that made the old "just re-run it" claim a lie).
#   2. reap any legacy pre-launchd nohup loops (narrow, bash-invoked matches only).
#   3. stop old runner containers BY SERVICE LABEL (arena-runner), now that nothing supervised is
#      live to recreate them.
#   4. install each plist with paths repointed at THIS checkout + $HOME via PlistBuddy (not sed —
#      no regex-metachar corruption of valid paths).
#   5. bootstrap egress FIRST (it raises the wall), then the two runners.
#
# Run on the runner host:  bash runner/install-launchd.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Single-value fallback (NOT `git ... || pwd` — that precedence prints both).
REPO_ROOT="$(git -C "$HERE/.." rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "$HERE/.." && pwd)"
UID_NUM="$(id -u)"
DOMAIN="gui/$UID_NUM"
LA_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"
PLISTBUDDY=/usr/libexec/PlistBuddy
# Egress FIRST so its wall is up before the runners bootstrap; runners self-heal if it isn't yet.
AGENTS=(com.daemon-engine.arena-egress com.daemon-engine.arena-privileged com.daemon-engine.arena-sandbox)

# PlistBuddy takes the remainder of its -c line as the value, which safely handles spaces and regex
# metacharacters (#, &, backslash) — but a newline or a double-quote in a path would break the command
# grammar. Those are pathological for a filesystem path; reject them explicitly rather than silently
# writing a corrupt plist, so the "path-safe rewrite" claim is honest.
case "$REPO_ROOT$LOG_DIR" in
  *\"*|*$'\n'*) echo "[install] ERROR: REPO_ROOT/LOG_DIR contains a quote or newline; refusing to rewrite plists." >&2; exit 1 ;;
esac

mkdir -p "$LA_DIR" "$LOG_DIR"

# --- 1. Bootout ALL agents first, then wait for them to actually disappear ------------------------
# bootout is asynchronous; bootstrapping (step 5) before teardown completes fails with
# "Bootstrap failed: 5: Input/output error". More importantly, KeepAlive treats a still-loaded
# agent's process death (from a stray pkill/docker stop below) as a clean exit and RELAUNCHES it —
# so we must remove the agents from launchd entirely BEFORE touching processes or containers.
for label in "${AGENTS[@]}"; do
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
done
for label in "${AGENTS[@]}"; do
  tries=0
  while launchctl print "$DOMAIN/$label" >/dev/null 2>&1; do
    tries=$((tries + 1))
    # Fail CLOSED: continuing while an agent is still loaded lets KeepAlive resurrect it the moment
    # step 2/3 touches its process — the exact race this ordering exists to prevent. A WARN-and-continue
    # is a fuse that never blows; abort instead so the operator resolves the stuck agent first.
    [ "$tries" -gt 60 ] && {
      echo "[install] ERROR: $label still loaded 30s after bootout — aborting to avoid a KeepAlive" >&2
      echo "          resurrection race. Resolve it by hand: launchctl bootout $DOMAIN/$label" >&2
      exit 1
    }
    sleep 0.5
  done
done

# Clear stale failure-backoff state so a fresh install doesn't inherit a prior storm's capped sleep
# (a runner would otherwise sit in a 300s backoff on its first post-install relaunch).
rm -f "${TMPDIR:-/tmp}"/arena-sandbox-consecutive-fails \
      "${TMPDIR:-/tmp}"/arena-privileged-consecutive-fails 2>/dev/null || true

# --- 2. Reap legacy pre-launchd nohup loops (narrow) ---------------------------------------------
# Only bash-INVOKED script processes, so an editor/pager/grep holding one of these paths open is not
# a target. The launchd-managed processes are already gone (step 1), so anything left is a real
# pre-launchd straggler.
for s in run-egress.sh run-privileged.sh run-sandbox.sh; do
  pkill -f "bash.*runner/$s" 2>/dev/null || true
done

# --- 3. Stop old runner containers by SERVICE LABEL ----------------------------------------------
# Target by identity (label=arena-runner), not image ancestry — ancestry also matches the OTHER
# runner and any manual test container from the same image. A graceful `docker stop` lets the
# ephemeral runner deregister itself from GitHub. Nothing supervised is live now (steps 1-2), so
# this cannot race a resurrected agent. (The tinyproxy proxy is a different image and unlabeled, so
# it is untouched here — the egress agent owns its lifecycle.)
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  old_containers="$(docker ps -q --filter "label=arena-runner" 2>/dev/null || true)"
  if [ -n "$old_containers" ]; then
    echo "[install] gracefully stopping old runner containers (label arena-runner)…"
    # shellcheck disable=SC2086
    docker stop $old_containers >/dev/null || true
  fi
  # Force a FRESH egress proxy on install. At runtime up-egress.sh deliberately REUSES a healthy proxy
  # (so a supervisor relaunch never drops live jobs) — but that means a reinstall from a moved/renamed
  # checkout, or after editing tinyproxy.conf/allowlist, would otherwise keep supervising the OLD
  # proxy with stale bind-mount paths. Install is the explicit "something changed" signal, so drop the
  # proxy here; the egress agent recreates it from THIS checkout when it bootstraps below.
  docker rm -f egress >/dev/null 2>&1 || true
fi

# --- 4+5. Install each plist (PlistBuddy path rewrite) and bootstrap ------------------------------
for label in "${AGENTS[@]}"; do
  src="$HERE/$label.plist"
  dst="$LA_DIR/$label.plist"
  [ -f "$src" ] || { echo "[install] missing plist: $src" >&2; exit 1; }
  cp "$src" "$dst"

  # Repoint the baked-in default paths at THIS checkout + $HOME. PlistBuddy Set takes literal
  # values — no sed/regex, so a path containing '#', '&', or a backslash cannot corrupt the plist.
  prog_base="$("$PLISTBUDDY" -c "Print :ProgramArguments:0" "$dst")"; prog_base="$(basename "$prog_base")"
  out_base="$("$PLISTBUDDY" -c "Print :StandardOutPath" "$dst")";     out_base="$(basename "$out_base")"
  err_base="$("$PLISTBUDDY" -c "Print :StandardErrorPath" "$dst")";   err_base="$(basename "$err_base")"
  "$PLISTBUDDY" -c "Set :ProgramArguments:0 $REPO_ROOT/runner/$prog_base" "$dst"
  "$PLISTBUDDY" -c "Set :WorkingDirectory $REPO_ROOT" "$dst"
  "$PLISTBUDDY" -c "Set :StandardOutPath $LOG_DIR/$out_base" "$dst"
  "$PLISTBUDDY" -c "Set :StandardErrorPath $LOG_DIR/$err_base" "$dst"

  # Bootstrap fresh (agents were booted out + confirmed gone in step 1). Retry once on the rare
  # residual-teardown race rather than aborting the whole install under `set -e`.
  if ! launchctl bootstrap "$DOMAIN" "$dst" 2>/dev/null; then
    sleep 1
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$dst"
  fi
  launchctl enable "$DOMAIN/$label" 2>/dev/null || true
  launchctl kickstart -k "$DOMAIN/$label" 2>/dev/null || true
  echo "[install] loaded $label"

  # After the egress agent, give the wall a moment to come up before the runners bootstrap — the
  # runners self-heal if it isn't ready (exit + relaunch), but waiting here avoids that launch churn
  # and the noisy failure logs during install. Best-effort: skip if docker isn't reachable.
  if [ "$label" = "com.daemon-engine.arena-egress" ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    w=0
    until docker network inspect arena-internal >/dev/null 2>&1 \
          && [ "$(docker inspect -f '{{.State.Running}}' egress 2>/dev/null)" = "true" ]; do
      w=$((w + 1))
      [ "$w" -gt 30 ] && { echo "[install] note: egress wall not up after 30s — runners will self-heal via relaunch" >&2; break; }
      sleep 1
    done
  fi
done

echo
echo "[install] done. Verify with:"
echo "  launchctl print $DOMAIN/com.daemon-engine.arena-egress | grep -E 'state|pid'"
echo "  docker ps --filter name=egress   # the wall's proxy should be up"
echo "  gh api repos/daemon-engine-labs/the-building-repo/actions/runners -q '.runners[].name'"
echo "  tail -f $LOG_DIR/arena-privileged.log $LOG_DIR/arena-sandbox.log $LOG_DIR/arena-egress.log"
