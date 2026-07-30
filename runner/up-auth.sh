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
IMAGE="arena-auth"
RESTART_POLICY="${AUTH_RESTART_POLICY:-unless-stopped}"

# Real token from the host env (NOT a GitHub Actions secret, NOT the plist). Fail closed if absent.
# shellcheck disable=SC1090
[ -f "$HOME/.claude/.env" ] && source "$HOME/.claude/.env"
REAL_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
[ -n "$REAL_OAUTH_TOKEN" ] || { echo "[arena-auth] CLAUDE_CODE_OAUTH_TOKEN not found in ~/.claude/.env — refusing to start a token-less proxy." >&2; exit 1; }

# ADMIN_TOKEN: host-only file, 0600, minted once. Never in git, never in the image.
ADMIN_FILE="$HOME/.arena-auth-admin"
if [ ! -s "$ADMIN_FILE" ]; then
  umask 077; head -c 32 /dev/urandom | base64 | tr -d '/+=' > "$ADMIN_FILE"
  echo "[arena-auth] minted a new ADMIN_TOKEN → $ADMIN_FILE (0600)"
fi
ADMIN_TOKEN="$(cat "$ADMIN_FILE")"

# Build the image if missing (or if server.mjs changed — cheap, it's a 2-file context).
docker build -q -t "$IMAGE" "$PWD/arena-auth" >/dev/null

# Networks: reuse the egress wall's networks so the sandbox already on arena-internal can reach us.
docker network inspect arena-internal >/dev/null 2>&1 || docker network create --internal arena-internal
docker network inspect arena-egress   >/dev/null 2>&1 || docker network create arena-egress

on_internal() { [ "$(docker inspect -f '{{if index .NetworkSettings.Networks "arena-internal"}}yes{{end}}' "$CONTAINER" 2>/dev/null)" = "yes" ]; }

# Reuse a HEALTHY container — a supervisor relaunch must not drop in-flight sandbox jobs.
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ] \
   && [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER" 2>/dev/null)" = "$RESTART_POLICY" ] \
   && on_internal; then
  echo "[arena-auth] already healthy (running, restart=$RESTART_POLICY, on arena-internal) — leaving it."
else
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  # Start on arena-egress (internet), inject secrets via env. ADMIN_BIND defaults to 127.0.0.1 in the
  # server, so admin is loopback-only inside the container — unreachable from the sandbox network.
  docker run -d --name "$CONTAINER" --network arena-egress --restart "$RESTART_POLICY" \
    -e REAL_OAUTH_TOKEN="$REAL_OAUTH_TOKEN" \
    -e ADMIN_TOKEN="$ADMIN_TOKEN" \
    "$IMAGE"
  # Bridge onto arena-internal, tolerating ONLY "already connected"; a swallowed real failure would
  # leave a half-wired proxy the sandbox can't reach. Then ASSERT the bridge (fail closed).
  if ! docker network connect arena-internal "$CONTAINER" 2>/tmp/auth-connect-err.$$; then
    grep -qiE 'already (exists|connected|in use)' /tmp/auth-connect-err.$$ || {
      echo "[arena-auth] FAILED to bridge onto arena-internal:" >&2; cat /tmp/auth-connect-err.$$ >&2
      rm -f /tmp/auth-connect-err.$$; exit 1
    }
  fi
  rm -f /tmp/auth-connect-err.$$
fi

on_internal || { echo "[arena-auth] NOT on arena-internal — refusing to report a half-wired proxy as up." >&2; exit 1; }
echo "[arena-auth] up (restart=$RESTART_POLICY); data plane reachable at http://$CONTAINER:8080 on arena-internal; admin loopback-only."
