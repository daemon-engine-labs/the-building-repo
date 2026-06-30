#!/usr/bin/env bash
# Phase 1c — the ephemeral sandbox runner loop.
# Each iteration: fetch a fresh registration token, run ONE job in a throwaway container
# (no host mounts, no secrets, forced through the egress proxy), then re-register.
# So every job gets a clean environment and a compromise cannot persist.
#
# Prereqs: `up-egress.sh` has run; image is built:
#   docker build -t arena-sandbox-runner -f runner/Dockerfile runner
# Auth: this loop runs on YOUR box and uses `gh` (your auth) to mint runner tokens.
set -euo pipefail

REPO="nickmeinhold/the-building-repo"
IMAGE="arena-sandbox-runner"
PROXY="http://egress:8888"

command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }

echo "[sandbox] starting ephemeral runner loop for $REPO (Ctrl-C to stop)"
while true; do
  TOKEN="$(gh api -X POST "repos/$REPO/actions/runners/registration-token" -q .token)"
  # --network arena-internal: no direct internet. Proxy env: only allowlisted hosts reachable.
  # --read-only + tmpfs: the container filesystem is ephemeral and non-persistent.
  docker run --rm \
    --network arena-internal \
    --read-only --tmpfs /tmp --tmpfs /home/runner/_work \
    -e HTTP_PROXY="$PROXY"  -e HTTPS_PROXY="$PROXY" \
    -e http_proxy="$PROXY"  -e https_proxy="$PROXY" \
    -e NO_PROXY="localhost,127.0.0.1" \
    "$IMAGE" bash -c "
      ./config.sh --url https://github.com/$REPO --token $TOKEN \
        --labels self-hosted,sandbox --ephemeral --unattended --replace \
        --name sandbox-\$(hostname)-\$\$ && ./run.sh
    " || echo "[sandbox] runner exited non-zero (will re-register)"
  echo "[sandbox] job complete; re-registering in 2s..."
  sleep 2
done
