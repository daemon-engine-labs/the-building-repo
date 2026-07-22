#!/usr/bin/env bash
# Phase 1b (supervised) — the egress WALL as a first-class launchd service.
#
# The sandbox runner has no route to the internet except through the tinyproxy sidecar on the
# arena-internal/arena-egress networks. Those networks + the proxy container are the "wall". Before
# this agent existed, nothing re-raised the wall after a reboot: the sandbox runner would find
# arena-internal missing, exit, and launchd would relaunch it every 10s forever (a thrash, not a
# self-heal). This agent closes that hole — launchd is now the SINGLE supervisor of the wall.
#
# Lifecycle: wait for docker, raise the wall idempotently (up-egress.sh), then `exec docker wait`
# on the proxy container. `docker wait` blocks for exactly as long as the proxy lives and returns
# the instant it dies — so this process's lifetime IS the wall's lifetime. When the proxy dies the
# agent exits, launchd (KeepAlive) relaunches it, and up-egress.sh re-raises the wall. No polling.
#
# Because launchd owns liveness here, up-egress.sh is told NOT to set a docker restart policy on the
# proxy (EGRESS_RESTART_POLICY=no) — two supervisors on one container would fight. See up-egress.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROXY_CONTAINER="egress"

# Drop bash's cached command→path table, then block until the docker daemon (colima VM) answers.
# `hash -r` re-resolves docker from PATH after any infra restart that moved the binary. A non-zero
# return makes the launchd agent exit and relaunch (self-healing boot ordering vs colima).
wait_for_docker() {
  local tries=0
  # hash -r EACH iteration (matching the runners): colima can move `docker` DURING the wait, and a
  # one-shot hash -r before the loop would keep the stale path and thrash under KeepAlive.
  until hash -r; docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt 60 ] && { echo "[egress] docker/colima not ready after 120s — exiting for relaunch" >&2; return 1; }
    echo "[egress] waiting for docker/colima ($tries)…"; sleep 2
  done
}

wait_for_docker || exit 1

# Raise the wall. up-egress.sh is idempotent: it ensures both networks exist and (re)creates the
# proxy. EGRESS_RESTART_POLICY=no hands sole liveness supervision to launchd (this agent).
echo "[egress] raising the wall (up-egress.sh)…"
EGRESS_RESTART_POLICY=no bash "$HERE/up-egress.sh"

# Pin this process's life to the proxy's. `docker wait` returns the container's exit code when it
# stops; if the container vanished between up-egress and here, `docker wait` errors non-zero and we
# exit for a prompt relaunch (which re-raises). Either way, proxy death ⇒ agent death ⇒ re-raise.
echo "[egress] wall up; supervising proxy container '$PROXY_CONTAINER' (exit on its death → relaunch re-raises)"
exec docker wait "$PROXY_CONTAINER"
