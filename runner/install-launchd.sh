#!/usr/bin/env bash
# Install the arena runners as launchd LaunchAgents (durable supervision — replaces nohup loops).
# Idempotent: safe to re-run. It (1) stops any old nohup loops, (2) ensures the egress wall is up,
# (3) copies the plists into ~/Library/LaunchAgents with paths rewritten to THIS checkout + $HOME,
# and (4) (re)bootstraps both agents. Run once on the runner host:  bash runner/install-launchd.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Single-value fallback (NOT `git ... || pwd` — that precedence prints both, and a two-line
# REPO_ROOT breaks the sed below with an embedded newline).
REPO_ROOT="$(git -C "$HERE/.." rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "$HERE/.." && pwd)"
UID_NUM="$(id -u)"
DOMAIN="gui/$UID_NUM"
LA_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"
IMAGE="arena-sandbox-runner"
AGENTS=(com.daemon-engine.arena-privileged com.daemon-engine.arena-sandbox)

mkdir -p "$LA_DIR" "$LOG_DIR"

# 1. Stop the legacy nohup loops AND their runner containers so we don't leave duplicate runners
#    registered. Containers are targeted BY IMAGE (--filter ancestor=), never by exclusion —
#    a graceful `docker stop` lets the ephemeral runner deregister itself from GitHub.
if pgrep -f 'run-sandbox.sh|run-privileged.sh' >/dev/null 2>&1; then
  echo "[install] stopping legacy nohup runner loops…"
  pkill -f 'run-sandbox.sh' 2>/dev/null || true
  pkill -f 'run-privileged.sh' 2>/dev/null || true
fi
old_containers="$(docker ps -q --filter "ancestor=$IMAGE" 2>/dev/null || true)"
if [ -n "$old_containers" ]; then
  echo "[install] gracefully stopping old runner containers (image $IMAGE)…"
  # shellcheck disable=SC2086
  docker stop $old_containers >/dev/null || true
fi

# 2. Ensure the egress wall (networks + tinyproxy) is up — the sandbox runner needs it.
echo "[install] ensuring egress wall is up…"
bash "$HERE/up-egress.sh"

# 3. Install each plist, rewriting the baked-in default paths to this checkout + this $HOME.
for label in "${AGENTS[@]}"; do
  src="$HERE/$label.plist"
  dst="$LA_DIR/$label.plist"
  [ -f "$src" ] || { echo "[install] missing plist: $src" >&2; exit 1; }
  # Repoint ProgramArguments/WorkingDirectory/logs at the real locations (self-heals if moved).
  sed -e "s#/Users/nick/git/experiments/the-building-repo#${REPO_ROOT}#g" \
      -e "s#/Users/nick/Library/Logs#${LOG_DIR}#g" \
      "$src" > "$dst"
  # Re-bootstrap: bootout the old instance (ignore if absent), then bootstrap + kickstart fresh.
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$dst"
  launchctl enable "$DOMAIN/$label" 2>/dev/null || true
  launchctl kickstart -k "$DOMAIN/$label" 2>/dev/null || true
  echo "[install] loaded $label"
done

echo
echo "[install] done. Verify with:"
echo "  launchctl print $DOMAIN/com.daemon-engine.arena-privileged | grep -E 'state|pid'"
echo "  gh api repos/daemon-engine-labs/the-building-repo/actions/runners -q '.runners[].name'"
echo "  tail -f $LOG_DIR/arena-privileged.log"
