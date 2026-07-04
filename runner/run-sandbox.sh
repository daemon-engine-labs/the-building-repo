#!/usr/bin/env bash
# Phase 1c — the ephemeral SANDBOX runner.
# Each job runs in a throwaway container (no host mounts, no secrets, forced through the egress
# proxy), then the runner re-registers. Every job gets a clean environment and a compromise
# cannot persist. This is where UNtrusted issue input runs, so it keeps the full egress wall.
#
# Supervision: prefer launchd (RUNNER_ONESHOT=1) so each job is a FRESH process with a correct
# environment — see runner/com.daemon-engine.arena-sandbox.plist + runner/install-launchd.sh.
# The old nohup while-loop wedged silently when colima moved the docker binary across an infra
# restart (bash kept a stale command hash); oneshot + `hash -r` below make that impossible.
#
# Prereqs: `up-egress.sh` has run; image built:
#   docker build -t arena-sandbox-runner -f runner/Dockerfile runner
# Auth: runs on YOUR box and uses `gh` (your auth) to mint runner tokens.
set -euo pipefail

REPO="daemon-engine-labs/the-building-repo"
IMAGE="arena-sandbox-runner"
PROXY="http://egress:8888"

command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }

# Drop bash's cached command→path table, block until the docker daemon (colima VM) answers, and
# assert the egress wall exists. `hash -r` re-resolves docker/gh from PATH after any infra restart
# that moved the binary — the exact failure that silently wedged the nohup loop. Any non-zero return
# makes the launchd agent exit and relaunch (self-healing boot ordering vs colima + up-egress).
wait_for_docker() {
  local tries=0
  hash -r
  until docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt 60 ] && { echo "[sandbox] docker/colima not ready after 120s — exiting for relaunch" >&2; return 1; }
    echo "[sandbox] waiting for docker/colima ($tries)…"; sleep 2
  done
  # The egress wall must be up: no arena-internal network → run.sh would have no route out.
  docker network inspect arena-internal >/dev/null 2>&1 || {
    echo "[sandbox] egress wall missing (arena-internal) — run runner/up-egress.sh first; exiting for relaunch" >&2
    return 1
  }
}

run_once() {
  wait_for_docker || return 1
  local token
  token="$(gh api -X POST "repos/$REPO/actions/runners/registration-token" -q .token)"
  # --network arena-internal: no direct internet. Proxy env: only allowlisted hosts reachable.
  # --rm + --ephemeral (below): the container is destroyed after one job — nothing persists.
  # (We do NOT use --read-only: the runner writes .env/.path/_diag/_work into its own home,
  #  which a read-only rootfs blocks. Ephemerality + network isolation + no secrets + no host
  #  mounts already bound the blast radius; read-only was redundant hardening. Named tradeoff.)
  docker run --rm \
    --network arena-internal \
    -e HTTP_PROXY="$PROXY"  -e HTTPS_PROXY="$PROXY" \
    -e http_proxy="$PROXY"  -e https_proxy="$PROXY" \
    -e NO_PROXY="localhost,127.0.0.1" \
    "$IMAGE" bash -c "
      ./config.sh --url https://github.com/$REPO --token $token \
        --labels self-hosted,sandbox --ephemeral --unattended --replace \
        --name sandbox-\$(hostname)-\$\$ && ./run.sh
    "
}

# RUNNER_ONESHOT=1 → run exactly one job and exit; launchd is the supervisor/loop (fresh process
# and env per job, KeepAlive re-registers). Unset → self-loop for manual/interactive use.
if [ -n "${RUNNER_ONESHOT:-}" ]; then
  echo "[sandbox] oneshot: registering one ephemeral runner for $REPO"
  run_once
else
  echo "[sandbox] starting ephemeral runner loop for $REPO (Ctrl-C to stop)"
  while true; do
    run_once || echo "[sandbox] runner exited non-zero (will re-register)"
    echo "[sandbox] job complete; re-registering in 2s…"
    sleep 2
  done
fi
