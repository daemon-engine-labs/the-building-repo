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

command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }

# Drop bash's cached command→path table, then block until the docker daemon (colima VM) answers.
# `hash -r` re-resolves docker/gh from PATH after any infra restart that moved the binary — the
# exact failure that silently wedged the nohup loop. Returns non-zero if docker never comes up so
# that, under launchd, the agent exits and is relaunched (self-healing boot ordering vs colima).
wait_for_docker() {
  local tries=0
  hash -r
  until docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt 60 ] && { echo "[privileged] docker/colima not ready after 120s — exiting for relaunch" >&2; return 1; }
    echo "[privileged] waiting for docker/colima ($tries)…"; sleep 2
  done
}

run_once() {
  wait_for_docker || return 1
  local token
  token="$(gh api -X POST "repos/$REPO/actions/runners/registration-token" -q .token)"
  # DIRECT egress (default bridge, normal NAT) — NOT behind the tinyproxy wall.
  # Rationale: the privileged runner executes only TRUSTED code (allowlisted actors / merged main),
  # so the egress wall (which exists to contain UNtrusted sandbox execution) buys little here and
  # the proxy was dropping claude's streaming API calls when it competed with the runner's own
  # persistent broker connection. Named tradeoff: broader egress on trusted code, for reliability.
  # The SANDBOX runner keeps its full egress wall — that's where untrusted input runs.
  docker run --rm \
    "$IMAGE" bash -c "
      ./config.sh --url https://github.com/$REPO --token $token \
        --labels self-hosted,privileged --ephemeral --unattended --replace \
        --name privileged-\$(hostname)-\$\$ && ./run.sh
    "
}

# RUNNER_ONESHOT=1 → run exactly one job and exit; launchd is the supervisor/loop (fresh process
# and env per job, KeepAlive re-registers). Unset → self-loop for manual/interactive use.
if [ -n "${RUNNER_ONESHOT:-}" ]; then
  echo "[privileged] oneshot: registering one ephemeral runner for $REPO"
  run_once
else
  echo "[privileged] starting ephemeral runner loop for $REPO (Ctrl-C to stop)"
  while true; do
    run_once || echo "[privileged] runner exited non-zero (will re-register)"
    echo "[privileged] job complete; re-registering in 2s…"
    sleep 2
  done
fi
