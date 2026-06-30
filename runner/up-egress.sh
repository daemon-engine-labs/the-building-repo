#!/usr/bin/env bash
# Phase 1b — stand up the egress wall: two docker networks + the tinyproxy sidecar.
# Idempotent: safe to re-run. Run once before run-sandbox.sh.
set -euo pipefail
cd "$(dirname "$0")"

# arena-internal: NO route to the internet. The runner lives here.
# arena-egress:   has internet. Only the proxy lives here.
docker network inspect arena-internal >/dev/null 2>&1 || docker network create --internal arena-internal
docker network inspect arena-egress   >/dev/null 2>&1 || docker network create arena-egress

# (Re)start the proxy, bridging both networks.
docker rm -f egress >/dev/null 2>&1 || true
docker run -d --name egress --network arena-egress --restart unless-stopped \
  -v "$PWD/tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro" \
  -v "$PWD/egress-allowlist.txt:/etc/tinyproxy/allowlist.txt:ro" \
  vimagick/tinyproxy
docker network connect arena-internal egress

echo "[egress] proxy up; runner network 'arena-internal' has no direct internet route."
