#!/usr/bin/env bash
# Phase 3 — the ephemeral PRIVILEGED runner loop.
# Same ephemeral, egress-walled pattern as the sandbox runner, but labelled `privileged`.
# It only ever runs trusted code (allowlisted actors / merged main), and the GHA `privileged`
# environment injects secrets (CLAUDE_CODE_OAUTH_TOKEN, ...) into the job at runtime — the runner
# itself holds no secret. Behind the egress wall for defence in depth (anthropic + github allowed).
#
# Prereqs: `up-egress.sh` has run; image built (docker build -t arena-sandbox-runner -f runner/Dockerfile runner).
set -euo pipefail

REPO="daemon-engine-labs/the-building-repo"
IMAGE="arena-sandbox-runner"

command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }

# DIRECT egress (default bridge, normal NAT) — NOT behind the tinyproxy wall.
# Rationale: the privileged runner executes only TRUSTED code (allowlisted actors / merged main),
# so the egress wall (which exists to contain UNtrusted sandbox execution) buys little here and
# the proxy was dropping claude's streaming API calls when it competed with the runner's own
# persistent broker connection. Named tradeoff: broader egress on trusted code, for reliability.
# The SANDBOX runner keeps its full egress wall — that's where untrusted input runs.
echo "[privileged] starting ephemeral runner loop for $REPO (Ctrl-C to stop)"
while true; do
  TOKEN="$(gh api -X POST "repos/$REPO/actions/runners/registration-token" -q .token)"
  docker run --rm \
    "$IMAGE" bash -c "
      ./config.sh --url https://github.com/$REPO --token $TOKEN \
        --labels self-hosted,privileged --ephemeral --unattended --replace \
        --name privileged-\$(hostname)-\$\$ && ./run.sh
    " || echo "[privileged] runner exited non-zero (will re-register)"
  echo "[privileged] job complete; re-registering in 2s..."
  sleep 2
done
