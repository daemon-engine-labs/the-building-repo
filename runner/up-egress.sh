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

# The proxy image is built locally from egress/Dockerfile and tagged by a hash of that file, so a change
# to the Dockerfile is a new tag that the reuse test below can see. Build only when the tag is missing:
# once built, a relaunch needs no registry (the wall must come up at boot even if Docker Hub can't be
# reached). Built BEFORE the reuse test, so a failed build aborts here and never tears down a running wall.
# Keep it `docker build`, not `docker buildx build`. The plain command always uses this context's
# docker-driver builder, which loads the image locally. `buildx build` follows the host-wide `buildx use`
# selection, which another project can set to a docker-container builder; that build exits 0 WITHOUT
# loading the image, so `docker run` below finds nothing and the wall stays down (measured 2026-10-31).
EGRESS_IMAGE="arena-egress-proxy:$(shasum -a 256 egress/Dockerfile | cut -c1-12)"
docker image inspect "$EGRESS_IMAGE" >/dev/null 2>&1 || docker build -q -t "$EGRESS_IMAGE" egress >/dev/null

# arena-internal: NO route to the internet. The runner lives here.
# arena-egress:   has internet. Only the proxy lives here.
docker network inspect arena-internal >/dev/null 2>&1 || docker network create --internal arena-internal
docker network inspect arena-egress   >/dev/null 2>&1 || docker network create arena-egress

# Structured membership test (not a JSON grep): `index` returns the arena-internal entry or nothing.
on_internal() { [ "$(docker inspect -f '{{if index .NetworkSettings.Networks "arena-internal"}}yes{{end}}' egress 2>/dev/null)" = "yes" ]; }

# Reuse a HEALTHY proxy — do not destroy the observed service just because a supervisor relaunched.
# A relaunch of run-egress.sh (e.g. `docker wait` returned transiently) must not drop in-flight
# sandbox jobs. Only (re)create when the proxy is absent, mis-policied, off the internal network, or
# running a different image. Without the image check a superseded proxy (e.g. the old amd64
# vimagick/tinyproxy) would be reused forever, until it happened to die. Compare image IDs, not the
# tag string: a tag rebuilt under a running container keeps its name but names different bytes.
if [ "$(docker inspect -f '{{.State.Running}}' egress 2>/dev/null)" = "true" ] \
   && [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' egress 2>/dev/null)" = "$RESTART_POLICY" ] \
   && [ "$(docker inspect -f '{{.Image}}' egress 2>/dev/null)" = "$(docker image inspect -f '{{.Id}}' "$EGRESS_IMAGE")" ] \
   && on_internal; then
  echo "[egress] proxy already healthy (running $EGRESS_IMAGE, restart=$RESTART_POLICY, on arena-internal) — leaving it in place."
else
  # -v: also remove the container's anonymous volumes. Without it, every recreate of an image that
  # declares a VOLUME orphans one (vimagick's VOLUME /etc/tinyproxy left 31,225 behind, one per crash).
  docker rm -fv egress >/dev/null 2>&1 || true
  # Least privilege for a component the hostile-code sandbox talks to directly: no capabilities,
  # no privilege gain, read-only root filesystem (tinyproxy writes nothing; see egress/Dockerfile).
  # BOTH networks at creation (Docker API >= 1.44), so the proxy is never running on arena-egress
  # alone. The old start-then-`network connect` had a half-wall state in between, guarded by stderr
  # classification; creating with both removes the state instead. arena-internal is --internal and
  # has no gateway, so the default route is always arena-egress's.
  docker run -d --name egress --network arena-egress --network arena-internal --restart "$RESTART_POLICY" \
    --read-only --cap-drop ALL --security-opt no-new-privileges \
    -v "$PWD/tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro" \
    -v "$PWD/egress-allowlist.txt:/etc/tinyproxy/allowlist.txt:ro" \
    "$EGRESS_IMAGE"
fi

# Postcondition, for both branches: the proxy MUST be on arena-internal, or the sandbox has no route
# out and would mint tokens into a dead network. Fail CLOSED rather than report a half-wall as up.
on_internal || { echo "[egress] proxy is NOT on arena-internal — refusing to report a half-wall as up." >&2; exit 1; }

echo "[egress] proxy up (restart=$RESTART_POLICY); runner network 'arena-internal' has no direct internet route."
