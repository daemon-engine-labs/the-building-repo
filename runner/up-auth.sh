#!/usr/bin/env bash
# Stand up arena-auth — the sandbox's spend trust boundary (DESIGN.md T1). Sibling of up-egress.sh.
# Idempotent: safe to re-run. Run once before run-sandbox.sh, or let com.daemon-engine.arena-auth
# supervise it (see run-auth.sh).
#
# TOPOLOGY (mirrors the egress wall):
#   - arena-egress   (has internet): arena-auth reaches api.anthropic.com here.
#   - arena-internal (NO internet):  the sandbox reaches arena-auth's DATA plane here.
# The container joins BOTH. The sandbox points ANTHROPIC_BASE_URL at http://arena-auth:8080 and sends
# its per-job NONCE as the bearer; arena-auth injects the real token and forwards to Anthropic.
#
# SECRETS never touch the tracked plist or the image. The real Claude token is sourced from the host
# (~/.claude/.env: CLAUDE_CODE_OAUTH_TOKEN) and passed via `docker run -e`. ADMIN_TOKEN is minted to a
# host-only file (~/.arena-auth-admin) on first run. The ADMIN plane binds container-LOOPBACK only, so
# it is unreachable from the sandbox network — mint nonces via `docker exec arena-auth …`.
#
# AUTH_RESTART_POLICY: like the egress wall — `unless-stopped` standalone; `no` under the launchd
# agent (run-auth.sh), which is the single supervisor and would otherwise fight docker's policy.
set -euo pipefail
cd "$(dirname "$0")"

CONTAINER="arena-auth"
RESTART_POLICY="${AUTH_RESTART_POLICY:-unless-stopped}"

# Real token from the host env (NOT a GitHub Actions secret, NOT the plist). Fail closed if absent.
# Parse ONLY the one var we need instead of `source`-ing the whole ~/.claude/.env (Carnot's catch:
# sourcing wholesale imports unrelated shell content into the launcher context).
REAL_OAUTH_TOKEN=""
if [ -f "$HOME/.claude/.env" ]; then
  # `|| true`: grep exits 1 on no-match, which under `set -e` would abort before the fail-closed
  # check below can emit its intended message (cage-match LOW).
  _line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?CLAUDE_CODE_OAUTH_TOKEN=' "$HOME/.claude/.env" | tail -1 || true)"
  REAL_OAUTH_TOKEN="${_line#*=}"; REAL_OAUTH_TOKEN="${REAL_OAUTH_TOKEN%\"}"; REAL_OAUTH_TOKEN="${REAL_OAUTH_TOKEN#\"}"
  REAL_OAUTH_TOKEN="${REAL_OAUTH_TOKEN%\'}"; REAL_OAUTH_TOKEN="${REAL_OAUTH_TOKEN#\'}"
fi
REAL_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-$REAL_OAUTH_TOKEN}"
[ -n "$REAL_OAUTH_TOKEN" ] || { echo "[arena-auth] CLAUDE_CODE_OAUTH_TOKEN not found in ~/.claude/.env — refusing to start a token-less proxy." >&2; exit 1; }

# ADMIN_TOKEN: host-only file, 0600, minted once. Never in git, never in the image.
ADMIN_FILE="$HOME/.arena-auth-admin"
if [ ! -s "$ADMIN_FILE" ]; then
  umask 077; head -c 32 /dev/urandom | base64 | tr -d '/+=' > "$ADMIN_FILE"
  echo "[arena-auth] minted a new ADMIN_TOKEN → $ADMIN_FILE (0600)"
fi
ADMIN_TOKEN="$(cat "$ADMIN_FILE")"

# Tag the image by a hash of its WHOLE build context and build only when that tag is missing — the same
# mechanism as up-egress.sh. Building on every run (the old way) moved the tag to a fresh image ID each
# time: this host uses the containerd image store, where BuildKit's provenance attestation makes even a
# fully cached rebuild a new ID (measured 2026-10-31). A stable tag is what lets the image-ID reuse test
# below mean "the source changed" rather than "a build ran". Built BEFORE the reuse test, so a failed
# build never tears down a running proxy. Keep `docker build`, not `buildx build` (see up-egress.sh).
IMAGE="arena-auth:$( (cd arena-auth && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) | shasum -a 256 | cut -c1-12)"
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -q -t "$IMAGE" "$PWD/arena-auth" >/dev/null

# Networks: reuse the egress wall's networks so the sandbox already on arena-internal can reach us.
docker network inspect arena-internal >/dev/null 2>&1 || docker network create --internal arena-internal
docker network inspect arena-egress   >/dev/null 2>&1 || docker network create arena-egress

on_internal() { [ "$(docker inspect -f '{{if index .NetworkSettings.Networks "arena-internal"}}yes{{end}}' "$CONTAINER" 2>/dev/null)" = "yes" ]; }

# Reuse a HEALTHY container — a supervisor relaunch must not drop in-flight sandbox jobs (a recreate
# also drops every outstanding nonce, which live only in the process). Recreate when the container is
# absent, mis-policied, off arena-internal, or running a different image ID than the current tag, so a
# merged server.mjs fix cannot stay dark behind a container that merely looks healthy.
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ] \
   && [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER" 2>/dev/null)" = "$RESTART_POLICY" ] \
   && [ "$(docker inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null)" = "$(docker image inspect -f '{{.Id}}' "$IMAGE")" ] \
   && on_internal; then
  echo "[arena-auth] already healthy (running $IMAGE, restart=$RESTART_POLICY, on arena-internal) — leaving it."
else
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
  # Create on BOTH networks at once (Docker API >= 1.44), so the proxy is never running half-wired on
  # arena-egress alone — the old start-then-`network connect` two-step needed stderr classification to
  # guard that state; this removes it. arena-internal is --internal (no gateway), so the default route,
  # and with it api.anthropic.com, stays on arena-egress. Secrets via env. ADMIN_BIND defaults to
  # 127.0.0.1 in the server, so admin is loopback-only inside the container — unreachable from the
  # sandbox network.
  docker run -d --name "$CONTAINER" --network arena-egress --network arena-internal --restart "$RESTART_POLICY" \
    -e REAL_OAUTH_TOKEN="$REAL_OAUTH_TOKEN" \
    -e ADMIN_TOKEN="$ADMIN_TOKEN" \
    "$IMAGE"
fi

# Postcondition, both branches: fail CLOSED rather than report a half-wired proxy as up.
on_internal || { echo "[arena-auth] NOT on arena-internal — refusing to report a half-wired proxy as up." >&2; exit 1; }
echo "[arena-auth] up (restart=$RESTART_POLICY); data plane reachable at http://$CONTAINER:8080 on arena-internal; admin loopback-only."
