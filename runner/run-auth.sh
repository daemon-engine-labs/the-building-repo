#!/usr/bin/env bash
# Durable supervisor for arena-auth (the spend trust boundary). Sibling of run-egress.sh.
#
# Lifecycle: wait for docker, raise the proxy idempotently (up-auth.sh), then `exec docker wait` on
# the container. `docker wait` blocks exactly as long as the proxy lives and returns the instant it
# dies — so this process's lifetime IS the proxy's. On death the agent exits, launchd (KeepAlive)
# relaunches it, and up-auth.sh re-raises. No polling. AUTH_RESTART_POLICY=no hands sole liveness
# supervision to launchd (two supervisors on one container would fight — same reasoning as egress).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONTAINER="arena-auth"

wait_for_docker() {
  local tries=0
  # hash -r EACH iteration: colima can move `docker` DURING the wait; a one-shot hash -r would keep a
  # stale path and thrash under KeepAlive.
  until hash -r; docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt 60 ] && { echo "[arena-auth] docker/colima not ready after 120s — exiting for relaunch" >&2; return 1; }
    echo "[arena-auth] waiting for docker/colima ($tries)…"; sleep 2
  done
}

wait_for_docker || exit 1

echo "[arena-auth] raising the proxy (up-auth.sh)…"
AUTH_RESTART_POLICY=no bash "$HERE/up-auth.sh"

echo "[arena-auth] up; supervising container '$CONTAINER' (exit on its death → relaunch re-raises)"
exec docker wait "$CONTAINER"
