#!/usr/bin/env bash
# Phase 1b — stand up the egress wall: two docker networks + the tinyproxy sidecar.
# Idempotent: safe to re-run. Run once before run-sandbox.sh, or let com.daemon-engine.arena-egress
# supervise it (see run-egress.sh).
#
# EGRESS_RESTART_POLICY controls the proxy container's docker restart policy:
#   - standalone/manual use (default): `unless-stopped`, so docker keeps the proxy alive on its own.
#   - under the launchd egress agent (EGRESS_RESTART_POLICY=no): launchd is the SINGLE supervisor —
#     it `docker wait`s on the proxy and re-raises the wall on death, so a docker-level restart
#     policy would be a second, fighting supervisor. run-egress.sh sets this to `no`.
set -euo pipefail
cd "$(dirname "$0")"

RESTART_POLICY="${EGRESS_RESTART_POLICY:-unless-stopped}"

# arena-internal: NO route to the internet. The runner lives here.
# arena-egress:   has internet. Only the proxy lives here.
docker network inspect arena-internal >/dev/null 2>&1 || docker network create --internal arena-internal
docker network inspect arena-egress   >/dev/null 2>&1 || docker network create arena-egress

# (Re)start the proxy, bridging both networks.
docker rm -f egress >/dev/null 2>&1 || true
docker run -d --name egress --network arena-egress --restart "$RESTART_POLICY" \
  -v "$PWD/tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro" \
  -v "$PWD/egress-allowlist.txt:/etc/tinyproxy/allowlist.txt:ro" \
  vimagick/tinyproxy
# Bridge into the internal network. Fresh container (rm -f above) so this is a first connect; guard
# it anyway to keep the whole script idempotent under any partial-state re-run.
docker network connect arena-internal egress 2>/dev/null || true

echo "[egress] proxy up (restart=$RESTART_POLICY); runner network 'arena-internal' has no direct internet route."
