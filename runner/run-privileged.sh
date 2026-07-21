#!/usr/bin/env bash
# Phase 3 — the ephemeral PRIVILEGED runner.
# Same ephemeral pattern as the sandbox runner, but labelled `privileged`. It only ever runs
# trusted code (allowlisted actors / merged main); the GHA `privileged` environment injects
# secrets (CLAUDE_CODE_OAUTH_TOKEN, ...) into the job at runtime — the runner itself holds none.
#
# Supervision: prefer launchd (RUNNER_ONESHOT=1) so each job is a FRESH process with a correct
# environment — see runner/com.daemon-engine.arena-privileged.plist + runner/install-launchd.sh.
# The old nohup while-loop wedged silently when colima moved the docker binary across an infra
# restart (bash kept a stale command hash); oneshot + `hash -r` below make that impossible.
#
# Prereqs: image built (docker build -t arena-sandbox-runner -f runner/Dockerfile runner).
set -euo pipefail

REPO="daemon-engine-labs/the-building-repo"
IMAGE="arena-sandbox-runner"
RUNNER_KIND="privileged"
# Host-side failure-backoff state: caps the registration-token mint rate when a job fails FAST after
# docker is already up, so KeepAlive's 10s throttle can't turn into a token-mint storm. See
# run_oneshot(). Mirrors the sandbox runner.
FAIL_STATE="${TMPDIR:-/tmp}/arena-${RUNNER_KIND}-consecutive-fails"
BACKOFF_BASE="${ARENA_BACKOFF_BASE:-10}"   # seconds
BACKOFF_CAP="${ARENA_BACKOFF_CAP:-300}"    # seconds

command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }

# Drop bash's cached command→path table, then block until the docker daemon (colima VM) answers.
# `hash -r` re-resolves docker/gh from PATH after any infra restart that moved the binary — the
# exact failure that silently wedged the nohup loop. A non-zero return means "infra not ready yet"
# (distinct from "job failed"): prompt relaunch, no backoff.
wait_for_docker() {
  local tries=0
  # hash -r EACH iteration: a colima binary move mid-wait must not be masked by a cached path.
  until hash -r; docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt 60 ] && { echo "[privileged] docker/colima not ready after 120s — exiting for relaunch" >&2; return 1; }
    echo "[privileged] waiting for docker/colima ($tries)…"; sleep 2
  done
}

# Register + run exactly one ephemeral job. Returns the container's exit status. Called only after
# wait_for_docker succeeds, so a non-zero return here is a real JOB failure (token already minted).
run_job() {
  local token
  token="$(gh api -X POST "repos/$REPO/actions/runners/registration-token" -q .token 2>/dev/null || true)"
  # Empty token = auth/keychain not ready, NOT a job failure. Return 2 → relaunch, no backoff.
  [ -n "$token" ] || { echo "[privileged] registration-token mint empty (gh auth/keychain not ready?) — relaunching" >&2; return 2; }
  # DIRECT egress (default bridge, normal NAT) — NOT behind the tinyproxy wall.
  # Rationale: the privileged runner executes only TRUSTED code (allowlisted actors / merged main),
  # so the egress wall (which exists to contain UNtrusted sandbox execution) buys little here and
  # the proxy was dropping claude's streaming API calls when it competed with the runner's own
  # persistent broker connection. Named tradeoff: broader egress on trusted code, for reliability.
  # The SANDBOX runner keeps its full egress wall — that's where untrusted input runs.
  # Host-side --name/--label so cleanup targets THIS runner by service identity, not image ancestry.
  # Token passed as a docker -e env var, expanded INSIDE the container (single-quoted inner script),
  # never interpolated into the host bash -c string — no metachar break/injection.
  # Remove any stale same-name container (killed prior script + PID reuse) so --name can't collide.
  docker rm -f "arena-privileged-$$" >/dev/null 2>&1 || true
  docker run --rm \
    --name "arena-privileged-$$" \
    --label arena-runner=privileged \
    -e ARENA_REPO="$REPO" \
    -e RUNNER_TOKEN="$token" \
    "$IMAGE" bash -c '
      ./config.sh --url "https://github.com/$ARENA_REPO" --token "$RUNNER_TOKEN" \
        --labels self-hosted,privileged --ephemeral --unattended --replace \
        --name "privileged-$(hostname)-$$" && ./run.sh
    '
}

# One supervised attempt under launchd. Splits "infra not ready" (relaunch fast) from "job failed
# after infra was ready" (back off, so we don't mint a fresh registration token every 10s forever).
run_oneshot() {
  if ! wait_for_docker; then
    exit 1   # infra not ready — bounded by the 120s internal wait; relaunch promptly, no backoff.
  fi
  local rc
  run_job; rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$FAIL_STATE"
    exit 0
  fi
  # rc==2 → token/auth not ready (not a job failure): relaunch promptly, no backoff.
  [ "$rc" -eq 2 ] && exit 1
  # rc==1 → re-probe: an infra blip after the gate is not a job failure, don't charge the backoff.
  if ! wait_for_docker; then
    echo "[privileged] failure coincided with infra going unready — relaunching without backoff" >&2
    exit 1
  fi
  local n backoff i raw
  # Sanitize a corrupt/partial FAIL_STATE so a bad arithmetic expansion can't abort the script.
  raw="$(tr -cd '0-9' < "$FAIL_STATE" 2>/dev/null)"
  n=$(( ${raw:-0} + 1 ))
  echo "$n" > "$FAIL_STATE"
  # Arithmetic loop, NOT `seq 2 $n`: BSD/macOS `seq 2 1` counts DOWN, doubling n=1 twice. `for ((...))`
  # yields zero iterations at n=1 as intended.
  backoff=$BACKOFF_BASE
  for (( i=2; i<=n; i++ )); do
    backoff=$(( backoff * 2 ))
    [ "$backoff" -ge "$BACKOFF_CAP" ] && { backoff=$BACKOFF_CAP; break; }
  done
  echo "[privileged] job failed ($n consecutive) — backing off ${backoff}s before exit/relaunch" >&2
  sleep "$backoff"
  exit 1
}

# RUNNER_ONESHOT=1 → run exactly one job and exit; launchd is the supervisor/loop (fresh process
# and env per job, KeepAlive re-registers). Unset → self-loop for manual/interactive use.
if [ -n "${RUNNER_ONESHOT:-}" ]; then
  echo "[privileged] oneshot: registering one ephemeral runner for $REPO"
  run_oneshot
else
  echo "[privileged] starting ephemeral runner loop for $REPO (Ctrl-C to stop)"
  while true; do
    wait_for_docker && run_job || echo "[privileged] runner exited non-zero (will re-register)"
    echo "[privileged] job complete; re-registering in 2s…"
    sleep 2
  done
fi
