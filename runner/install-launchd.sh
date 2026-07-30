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
# The DEPLOY worktree — a dedicated, CI-fast-forwarded checkout the SUPERVISED services exec from, so
# the running process is NEVER coupled to whatever branch a dev session has checked out at REPO_ROOT
# (merge→run integrity — see runner/README.md + arena-autopull.sh). A dot-path signals "regenerable,
# do not hand-edit". Overridable for tests via ARENA_DEPLOY_ROOT.
DEPLOY_ROOT="${ARENA_DEPLOY_ROOT:-$HOME/.arena-deploy}"
UID_NUM="$(id -u)"
DOMAIN="gui/$UID_NUM"
LA_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"
PLISTBUDDY=/usr/libexec/PlistBuddy
# Egress FIRST so its wall is up before the runners bootstrap; runners self-heal if it isn't yet.
# Egress FIRST (raises the wall), then arena-auth (the spend trust boundary — reuses the wall's
# networks; up-auth.sh creates them if egress hasn't yet), then the two runners.
AGENTS=(com.daemon-engine.arena-egress com.daemon-engine.arena-auth com.daemon-engine.arena-privileged com.daemon-engine.arena-sandbox com.daemon-engine.arena-autopull)

# PlistBuddy takes the remainder of its -c line as the value, which safely handles spaces and regex
# metacharacters (#, &, backslash) — but a newline or a double-quote in a path would break the command
# grammar. Those are pathological for a filesystem path; reject them explicitly rather than silently
# writing a corrupt plist, so the "path-safe rewrite" claim is honest.
case "$REPO_ROOT$DEPLOY_ROOT$LOG_DIR" in
  *\"*|*$'\n'*) echo "[install] ERROR: REPO_ROOT/DEPLOY_ROOT/LOG_DIR contains a quote or newline; refusing to rewrite plists." >&2; exit 1 ;;
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

# Clear stale failure-backoff state so a fresh install doesn't inherit a prior storm's capped sleep.
# Same stable $HOME path the runners use (NOT TMPDIR — the installer shell and the launchd agent get
# different per-session TMPDIRs, so a TMPDIR clear here would never reach the agent's state file).
rm -f "$HOME/.arena-sandbox.fails" "$HOME/.arena-privileged.fails" 2>/dev/null || true

# --- 2. Reap legacy pre-launchd nohup loops (narrow) ---------------------------------------------
# Only bash-INVOKED script processes, so an editor/pager/grep holding one of these paths open is not
# a target. The launchd-managed processes are already gone (step 1), so anything left is a real
# pre-launchd straggler.
for s in run-egress.sh run-auth.sh run-privileged.sh run-sandbox.sh; do
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
  # Same reasoning for arena-auth (the spend trust boundary): up-auth.sh REUSES a healthy container
  # at runtime, so a security fix to server.mjs would stay dark under KeepAlive's "already healthy"
  # unless install force-drops it. Install is the explicit "something changed" signal (Tesla's PR #17
  # catch: stale trust-boundary container survives rebuild); the arena-auth agent recreates it from
  # THIS checkout when it bootstraps.
  docker rm -f arena-auth >/dev/null 2>&1 || true
fi

# --- 3b. Ensure the DEPLOY worktree exists and is current ----------------------------------------
# The supervised services exec from $DEPLOY_ROOT, not the dev checkout at $REPO_ROOT. It is a linked
# git worktree (shares $REPO_ROOT's object store — cheap, no second clone) checked out DETACHED at
# origin/main: detached because a worktree may not share a branch name with another checkout, and a
# deploy target wants a pinned commit anyway. arena-autopull.sh fast-forwards it on every merge.
# Idempotent: if it is already a worktree we just fetch + ff it to origin/main here so a reinstall
# lands current. Fail-CLOSED: if we cannot establish a clean deploy tree, abort — better no runners
# than runners on an unknown tree.
git -C "$REPO_ROOT" fetch --quiet origin main || { echo "[install] ERROR: git fetch origin main failed — cannot establish deploy worktree." >&2; exit 1; }
# Recognize an existing deploy tree ONLY as a LINKED worktree of THIS repo — a linked worktree's .git
# is a FILE (a gitdir: pointer), whereas a standalone clone's .git is a DIRECTORY. Testing
# `--is-inside-work-tree` alone is true for ANY git checkout, so an unrelated standalone clone at
# $DEPLOY_ROOT would be fast-forwarded toward OUR origin/main (Tesla). Require the .git-FILE marker AND
# that its common dir belongs to $REPO_ROOT, else refuse.
# Resolve a repo's git COMMON dir to an absolute, symlink-canonical path. `--git-common-dir` can be
# RELATIVE (e.g. ".git"), and it must be resolved relative to THAT repo's dir, not the installer's CWD
# (Carnot MEDIUM — a relative `cd "$_repo_git"` from outside the repo mis-resolved). And we compare
# common-dir↔common-dir, never common-dir↔git-dir: run from a SECONDARY worktree, git-dir is
# `.git/worktrees/<name>` while common-dir is the shared store, so a git-dir compare false-negatives a
# healthy deploy tree (Tesla). cd into the repo FIRST so a relative common-dir resolves correctly.
abs_common_dir() {   # $1 = a dir inside a git repo; echoes the canonical absolute git common dir
  ( cd "$1" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P )
}
DEPLOY_IS_LINKED_WORKTREE=0
if [ -f "$DEPLOY_ROOT/.git" ]; then
  _deploy_common="$(abs_common_dir "$DEPLOY_ROOT")"
  _repo_common="$(abs_common_dir "$REPO_ROOT")"
  if [ -n "$_deploy_common" ] && [ -n "$_repo_common" ] && [ "$_deploy_common" = "$_repo_common" ]; then
    DEPLOY_IS_LINKED_WORKTREE=1
  fi
fi
if [ "$DEPLOY_IS_LINKED_WORKTREE" = "1" ]; then
  echo "[install] deploy worktree exists at $DEPLOY_ROOT — fast-forwarding to origin/main"
  # ff-only ONLY. Do NOT fall back to `checkout --detach origin/main`: that would silently discard any
  # local commits in the deploy tree (Carnot HIGH — fail-OPEN on the exact anomaly the guard exists to
  # surface). Mirror arena-autopull.sh's fail-closed stance: refuse loudly, keep git's real error.
  if ! _ffout="$(git -C "$DEPLOY_ROOT" merge --ff-only origin/main 2>&1)"; then
    echo "[install] ERROR: deploy worktree at $DEPLOY_ROOT could not fast-forward to origin/main — it may have diverged (local commits?). Resolve by hand; refusing to force." >&2
    echo "[install]        git said: $_ffout" >&2
    exit 1
  fi
elif [ -e "$DEPLOY_ROOT" ]; then
  echo "[install] ERROR: $DEPLOY_ROOT exists but is not a linked worktree of $REPO_ROOT (a standalone clone or foreign dir?) — refusing to clobber it." >&2
  exit 1
else
  echo "[install] creating deploy worktree at $DEPLOY_ROOT (detached @ origin/main)"
  if ! _wtout="$(git -C "$REPO_ROOT" worktree add --detach "$DEPLOY_ROOT" origin/main 2>&1)"; then
    echo "[install] ERROR: git worktree add failed for $DEPLOY_ROOT. git said: $_wtout" >&2
    exit 1
  fi
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
  # Supervised services exec from the DEPLOY worktree, never the dev checkout — this is the coupling
  # removal that makes "merged == running" true. (The installer still RUNS from $REPO_ROOT/$HERE; only
  # the installed services are repointed.)
  "$PLISTBUDDY" -c "Set :ProgramArguments:0 $DEPLOY_ROOT/runner/$prog_base" "$dst"
  "$PLISTBUDDY" -c "Set :WorkingDirectory $DEPLOY_ROOT" "$dst"
  "$PLISTBUDDY" -c "Set :StandardOutPath $LOG_DIR/$out_base" "$dst"
  "$PLISTBUDDY" -c "Set :StandardErrorPath $LOG_DIR/$err_base" "$dst"
  # autopull carries an ARENA_DEPLOY_ROOT env var (the tree it fetches+ff's); repoint it too when present.
  if "$PLISTBUDDY" -c "Print :EnvironmentVariables:ARENA_DEPLOY_ROOT" "$dst" >/dev/null 2>&1; then
    "$PLISTBUDDY" -c "Set :EnvironmentVariables:ARENA_DEPLOY_ROOT $DEPLOY_ROOT" "$dst"
  fi

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
    # Use the SAME three-part readiness predicate the sandbox runner gates on (network exists AND
    # proxy Running AND bridged onto arena-internal) — a weaker check here would declare the wall up
    # and bootstrap runners into a half-built network, defeating the whole point of waiting.
    w=0
    until docker network inspect arena-internal >/dev/null 2>&1 \
          && [ "$(docker inspect -f '{{.State.Running}}' egress 2>/dev/null)" = "true" ] \
          && [ "$(docker inspect -f '{{if index .NetworkSettings.Networks "arena-internal"}}yes{{end}}' egress 2>/dev/null)" = "yes" ]; do
      w=$((w + 1))
      [ "$w" -gt 30 ] && { echo "[install] note: egress wall not up after 30s — runners will self-heal via relaunch" >&2; break; }
      sleep 1
    done
  fi
done

echo
echo "[install] done. Deploy worktree: $DEPLOY_ROOT (services exec from here, not $REPO_ROOT). Verify with:"
echo "  launchctl print $DOMAIN/com.daemon-engine.arena-egress | grep -E 'state|pid'"
echo "  launchctl print $DOMAIN/com.daemon-engine.arena-auth | grep -E 'state|pid'"
echo "  launchctl print $DOMAIN/com.daemon-engine.arena-autopull | grep -E 'state|pid'  # merge→run daemon"
echo "  launchctl print $DOMAIN/com.daemon-engine.arena-sandbox | grep -E 'ProgramArguments' -A2  # points at $DEPLOY_ROOT"
echo "  docker ps --filter name=egress --filter name=arena-auth  # wall + spend-boundary proxies up"
echo "  gh api repos/daemon-engine-labs/the-building-repo/actions/runners -q '.runners[].name'"
echo "  tail -f $LOG_DIR/arena-privileged.log $LOG_DIR/arena-sandbox.log $LOG_DIR/arena-egress.log $LOG_DIR/arena-autopull.log"
