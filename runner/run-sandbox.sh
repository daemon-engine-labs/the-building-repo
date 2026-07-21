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
# Prereqs: the egress wall is up (com.daemon-engine.arena-egress / up-egress.sh); image built:
#   docker build -t arena-sandbox-runner -f runner/Dockerfile runner
# Auth: runs on YOUR box and uses `gh` (your auth) to mint runner tokens.
set -euo pipefail

REPO="daemon-engine-labs/the-building-repo"
IMAGE="arena-sandbox-runner"
PROXY="http://egress:8888"
RUNNER_KIND="sandbox"
# Host-side failure-backoff state: caps the registration-token mint rate when a job fails FAST after
# docker is already up (a bad image / config.sh death), so KeepAlive's 10s throttle can't turn into a
# token-mint storm against GitHub. Reset on any clean job. See run_oneshot().
FAIL_STATE="${TMPDIR:-/tmp}/arena-${RUNNER_KIND}-consecutive-fails"
BACKOFF_BASE="${ARENA_BACKOFF_BASE:-10}"   # seconds
BACKOFF_CAP="${ARENA_BACKOFF_CAP:-300}"    # seconds

command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }

# Drop bash's cached command→path table, block until the docker daemon (colima VM) answers, and
# assert the egress wall exists. `hash -r` re-resolves docker/gh from PATH after any infra restart
# that moved the binary — the exact failure that silently wedged the nohup loop. A non-zero return
# means "infra not ready yet" (distinct from "job failed"): prompt relaunch, no backoff.
wait_for_docker() {
  local tries=0
  # hash -r EACH iteration: a colima binary move mid-wait (after the first successful `docker info`
  # or between iterations) must not be masked by a cached path — matches the README's belt-and-braces.
  until hash -r; docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt 60 ] && { echo "[sandbox] docker/colima not ready after 120s — exiting for relaunch" >&2; return 1; }
    echo "[sandbox] waiting for docker/colima ($tries)…"; sleep 2
  done
  # The egress wall must be FUNCTIONAL, not merely named. Checking that arena-internal EXISTS is not
  # enough: after a reboot/colima flap the network can linger while the proxy is down or mid-recreate.
  # If we passed on existence alone we'd mint a registration token into a dead route, then burn the
  # failure-backoff. So require BOTH the network AND a running proxy; a not-yet-ready wall is treated
  # like infra (exit for relaunch, no mint, no FAIL_STATE) — the arena-egress agent is raising it.
  docker network inspect arena-internal >/dev/null 2>&1 || {
    echo "[sandbox] egress wall not up yet (arena-internal missing) — exiting for relaunch" >&2
    return 1
  }
  [ "$(docker inspect -f '{{.State.Running}}' egress 2>/dev/null)" = "true" ] || {
    echo "[sandbox] egress proxy not running yet — exiting for relaunch" >&2
    return 1
  }
}

# Register + run exactly one ephemeral job. Returns the container's exit status. Called only after
# wait_for_docker succeeds, so a non-zero return here is a real JOB failure (token already minted).
run_job() {
  local token
  token="$(gh api -X POST "repos/$REPO/actions/runners/registration-token" -q .token)"
  # Host-side --name/--label so cleanup can target THIS runner's containers by service identity
  # rather than by image ancestry (which also matches the privileged runner and manual test
  # containers). $$ = this oneshot's pid → unique per launch.
  # Token is passed as a docker -e env var and expanded INSIDE the container (single-quoted inner
  # script), never interpolated into the host's bash -c string — so a token with shell
  # metacharacters can't break or inject into the command.
  # Remove any stale same-name container (a killed prior script that didn't --rm, then PID reuse) so
  # --name can't collide and wedge us into backoff before the runner can even deregister.
  docker rm -f "arena-sandbox-$$" >/dev/null 2>&1 || true
  docker run --rm \
    --name "arena-sandbox-$$" \
    --label arena-runner=sandbox \
    --network arena-internal \
    -e HTTP_PROXY="$PROXY"  -e HTTPS_PROXY="$PROXY" \
    -e http_proxy="$PROXY"  -e https_proxy="$PROXY" \
    -e NO_PROXY="localhost,127.0.0.1" \
    -e ARENA_REPO="$REPO" \
    -e RUNNER_TOKEN="$token" \
    "$IMAGE" bash -c '
      ./config.sh --url "https://github.com/$ARENA_REPO" --token "$RUNNER_TOKEN" \
        --labels self-hosted,sandbox --ephemeral --unattended --replace \
        --name "sandbox-$(hostname)-$$" && ./run.sh
    '
}

# One supervised attempt under launchd. Splits "infra not ready" (relaunch fast) from "job failed
# after infra was ready" (back off, so we don't mint a fresh registration token every 10s forever).
run_oneshot() {
  if ! wait_for_docker; then
    exit 1   # infra not ready — bounded by the 120s internal wait; relaunch promptly, no backoff.
  fi
  if run_job; then
    rm -f "$FAIL_STATE"
    exit 0
  fi
  # Failed AFTER docker+egress were ready → a real job failure that already minted a token. Back off
  # exponentially (capped) before exiting so KeepAlive's relaunch cadence — and the token-mint rate —
  # grows instead of hammering GitHub at a fixed 10s.
  local n backoff i
  n=$(( $(cat "$FAIL_STATE" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$FAIL_STATE"
  # Arithmetic loop, NOT `seq 2 $n`: BSD/macOS `seq 2 1` counts DOWN ("2 1"), so n=1 would double
  # twice (10→40) instead of staying at BASE. `for ((...))` yields zero iterations at n=1 as intended.
  backoff=$BACKOFF_BASE
  for (( i=2; i<=n; i++ )); do
    backoff=$(( backoff * 2 ))
    [ "$backoff" -ge "$BACKOFF_CAP" ] && { backoff=$BACKOFF_CAP; break; }
  done
  echo "[sandbox] job failed ($n consecutive) — backing off ${backoff}s before exit/relaunch" >&2
  sleep "$backoff"
  exit 1
}

# RUNNER_ONESHOT=1 → run exactly one job and exit; launchd is the supervisor/loop (fresh process
# and env per job, KeepAlive re-registers). Unset → self-loop for manual/interactive use.
if [ -n "${RUNNER_ONESHOT:-}" ]; then
  echo "[sandbox] oneshot: registering one ephemeral runner for $REPO"
  run_oneshot
else
  echo "[sandbox] starting ephemeral runner loop for $REPO (Ctrl-C to stop)"
  while true; do
    wait_for_docker && run_job || echo "[sandbox] runner exited non-zero (will re-register)"
    echo "[sandbox] job complete; re-registering in 2s…"
    sleep 2
  done
fi
