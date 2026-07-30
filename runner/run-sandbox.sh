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
# Stable, launchd-independent path. launchd agents get a per-session TMPDIR under /var/folders/, so a
# TMPDIR path would neither match the installer's clear nor be predictable; a fixed $HOME dotfile is.
FAIL_STATE="$HOME/.arena-${RUNNER_KIND}.fails"
BACKOFF_BASE="${ARENA_BACKOFF_BASE:-10}"   # seconds
BACKOFF_CAP="${ARENA_BACKOFF_CAP:-300}"    # seconds
# Resolve the worktree we are ACTUALLY executing from (the script's own dir), not $PWD — so the drift
# stamp reports the tree that runs, which is the whole point when a launchd service execs from a
# working tree that a merge may have moved past. See runner/README.md "merge→run integrity".
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }

# Log the executing worktree's SHA vs the last-known origin/main so merge→run drift is VISIBLE in the
# runner log (feedback_service_runs_from_git_working_tree: merged code is not running code). Read-ONLY
# and it NEVER fetches — registration stays cheap and offline-safe, and arena-autopull.sh owns the
# fetch+ff+relaunch. Fully `|| true`-guarded and always `return 0`: a detached HEAD, a missing
# origin/main ref, or a non-repo dir must never abort run_job under `set -e` and wedge the fail-open
# gate path. The origin/main it compares against is only as fresh as the last fetch (best-effort
# visibility on the dev tree; kept current by autopull on the deploy worktree).
drift_stamp() {
  local run ref
  run="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  ref="$(git -C "$SCRIPT_DIR" rev-parse --short origin/main 2>/dev/null || true)"
  if [ -z "$run" ]; then
    echo "[sandbox] drift-stamp: $SCRIPT_DIR is not a git worktree — skipping" >&2
    return 0
  fi
  if [ -n "$ref" ] && [ "$run" != "$ref" ]; then
    echo "[sandbox] ⚠ DRIFT: running SHA $run != origin/main $ref — this process predates a merge; arena-autopull should relaunch it" >&2
  else
    echo "[sandbox] running SHA $run (origin/main ${ref:-unknown})" >&2
  fi
  return 0
}

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
  # Running is not enough: the proxy must be BRIDGED onto arena-internal, or the sandbox (which lives
  # only on arena-internal) still has no route out. A disconnect/recreate race can leave a Running
  # proxy attached to arena-egress alone — a mute wall. Assert the bridge before we mint a token.
  [ "$(docker inspect -f '{{if index .NetworkSettings.Networks "arena-internal"}}yes{{end}}' egress 2>/dev/null)" = "yes" ] || {
    echo "[sandbox] egress proxy not on arena-internal yet (half-wall) — exiting for relaunch" >&2
    return 1
  }
}

# Per-job spend nonce from arena-auth (DESIGN.md T1 — the sandbox's spend trust boundary). arena-auth's
# admin plane is container-LOOPBACK, so only host docker access can mint; this launcher is that place.
# BEST-EFFORT by design: if arena-auth is down we launch the runner WITHOUT a nonce. The gate and (via
# the privileged launcher) trusted paths never need model access, so a dead proxy must NOT wedge them —
# fail-OPEN on availability. But a build-sandbox job that lands token-less simply FAILS to reach a model
# (fail-CLOSED on security): there is no real-token fallback, ever. The nonce is single-use, budget-
# capped, and revoked the instant the job ends (mint_nonce/revoke_nonce), so a leaked nonce dies with
# the job. The proxy clamps every mint to its own server-side ceilings regardless of this request.
mint_nonce() {
  local out
  out="$(docker exec arena-auth node server.mjs mint 2>/dev/null || true)"
  # Extract the FIRST "nonce":"…" field, dependency-free (no jq/node-on-host-PATH assumption). grep -o
  # + head -1 grabs only the first match, so stray log lines or multiple JSON objects can't make us
  # capture the wrong value the way a greedy whole-line sed could (cage-match round 2 — Carnot/Tesla).
  # Trailing `|| true` is LOAD-BEARING: grep exits 1 on no-match (empty mint = arena-auth down) and
  # head can SIGPIPE non-zero even on success, both of which — under the script's `set -euo pipefail` —
  # would make `NONCE="$(mint_nonce)"` abort run_job and WEDGE the runner (incl. gate), breaking the
  # fail-OPEN-on-availability property. `|| true` forces a 0 exit so an empty nonce falls through to the
  # token-less launch branch as designed (cage-match round 4 — Tesla: a round-3 regression).
  printf '%s' "$out" | grep -oE '"nonce":"[^"]*"' | head -1 | sed 's/"nonce":"\([^"]*\)"/\1/' || true
}
revoke_nonce() {
  [ -n "${1:-}" ] || return 0
  docker exec arena-auth node server.mjs revoke "$1" >/dev/null 2>&1 || true
}

# Signal-safe nonce cleanup. Revoke on EVERY exit path — normal return, a `set -e` abort,
# OR a launchd/SIGTERM kill mid-`docker run` (cage-match: revoke was straight-line-only, so
# a kill leaked a live spend nonce until the proxy's next restart; a revoked nonce also
# neuters any orphaned --rm container that outlives us, since the proxy rejects it). NONCE is
# script-GLOBAL so the trap can still see it after run_job's local frame is gone. The EXIT
# trap covers normal + set-e exits; INT/TERM revoke then exit (which re-fires EXIT as a no-op,
# NONCE already cleared).
NONCE=""
# Explicitly TOTAL (always returns 0) so the trap can never be made brittle by revoke's status: under
# `set -e`, a cleanup that returned non-zero could suppress on_signal's `exit 143` (cage-match round 2 —
# Carnot/Tesla). `if…fi; return 0` makes that independent of any future edit to revoke_nonce.
cleanup_nonce() { if [ -n "${NONCE:-}" ]; then revoke_nonce "$NONCE" || true; NONCE=""; fi; return 0; }
# Convention-correct exit codes so a supervisor/log can tell a user interrupt (130) from a supervisor
# termination (143): 128 + signal number (cage-match r3 — Carnot). cleanup_nonce runs first either way.
on_signal() { cleanup_nonce; exit "${1:-143}"; }
trap cleanup_nonce EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

# Register + run exactly one ephemeral job. Returns the container's exit status. Called only after
# wait_for_docker succeeds, so a non-zero return here is a real JOB failure (token already minted).
run_job() {
  local token
  drift_stamp   # visible merge→run drift check (read-only, best-effort) before we register
  token="$(gh api -X POST "repos/$REPO/actions/runners/registration-token" -q .token 2>/dev/null || true)"
  # Empty token = auth/keychain not ready (e.g. locked login keychain just after reboot), NOT a job
  # failure. Return 2 so run_oneshot relaunches promptly without charging the failure-backoff.
  [ -n "$token" ] || { echo "[sandbox] registration-token mint empty (gh auth/keychain not ready?) — relaunching" >&2; return 2; }
  # Host-side --name/--label so cleanup can target THIS runner's containers by service identity
  # rather than by image ancestry (which also matches the privileged runner and manual test
  # containers). $$ = this oneshot's pid → unique per launch.
  # The registration token is piped to the container over STDIN and read into a NON-EXPORTED shell var
  # (never `-e RUNNER_TOKEN`): a `-e` value lands in PID 1's /proc/1/environ, readable by the untrusted
  # agent (same UID) even after `unset` — a self-hosted runner REGISTRATION credential that could attach
  # rogue runners. Via stdin it is never in the environment or in the host bash -c string; config.sh
  # consumes it and exits before ./run.sh (and the job) starts (cage-match round 4 — Carnot HIGH).
  # Remove any stale same-name container (a killed prior script that didn't --rm, then PID reuse) so
  # --name can't collide and wedge us into backoff before the runner can even deregister.
  docker rm -f "arena-sandbox-$$" >/dev/null 2>&1 || true

  # Mint the per-job spend nonce. Only inject the model-access env when a nonce actually exists — an
  # empty ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN could read as a mis-set base URL to the CLI, so we
  # add those -e flags conditionally rather than passing empty strings.
  local auth_env=()
  NONCE="$(mint_nonce)"   # script-global so the EXIT/TERM trap can revoke it on a kill mid-job
  if [ -n "$NONCE" ]; then
    echo "[sandbox] minted a per-job spend nonce (arena-auth data plane at http://arena-auth:8080)" >&2
    auth_env=( -e ANTHROPIC_BASE_URL="http://arena-auth:8080" -e ANTHROPIC_AUTH_TOKEN="$NONCE" )
  else
    echo "[sandbox] WARNING: arena-auth mint failed/absent — launching token-less; propose builds will have NO model access (never a real-token fallback)" >&2
  fi

  # NO_PROXY/no_proxy must include arena-auth: the sandbox forces all egress through tinyproxy, whose
  # allowlist only knows EXTERNAL hosts. arena-auth is an internal docker name on arena-internal, so the
  # one hop the whole credential-off-sandbox design depends on has to bypass the proxy. BOTH cases are
  # set because the client matrix is mixed — curl/Python honor lowercase `no_proxy` only, some Node
  # stacks uppercase only (cage-match: uppercase-only was a half-wired bypass). Harmless when unused.
  local rc=0
  # `-i` keeps stdin open; the token is delivered as ONE newline-terminated line (so `read` returns 0
  # under set -e) and read into a non-exported var inside the container. No -e RUNNER_TOKEN.
  printf '%s\n' "$token" | docker run --rm -i \
    --name "arena-sandbox-$$" \
    --label arena-runner=sandbox \
    --network arena-internal \
    -e HTTP_PROXY="$PROXY"  -e HTTPS_PROXY="$PROXY" \
    -e http_proxy="$PROXY"  -e https_proxy="$PROXY" \
    -e NO_PROXY="localhost,127.0.0.1,arena-auth" \
    -e no_proxy="localhost,127.0.0.1,arena-auth" \
    -e ARENA_REPO="$REPO" \
    ${auth_env[@]+"${auth_env[@]}"} \
    "$IMAGE" bash -c '
      IFS= read -r RUNNER_TOKEN   # from stdin, NOT the environment — never reaches /proc/1/environ
      ./config.sh --url "https://github.com/$ARENA_REPO" --token "$RUNNER_TOKEN" \
        --labels self-hosted,sandbox --ephemeral --unattended --replace \
        --name "sandbox-$(hostname)-$$" \
        && unset RUNNER_TOKEN \
        && ./run.sh
    ' || rc=$?

  # Revoke the nonce the instant the ephemeral job ends (the EXIT/TERM trap is the backstop for a kill
  # mid-job). cleanup_nonce revokes + clears NONCE, so the trap is then a no-op. Never changes rc.
  cleanup_nonce
  return "$rc"
}

# One supervised attempt under launchd. Splits "infra not ready" (relaunch fast) from "job failed
# after infra was ready" (back off, so we don't mint a fresh registration token every 10s forever).
run_oneshot() {
  if ! wait_for_docker; then
    exit 1   # infra not ready — bounded by the 120s internal wait; relaunch promptly, no backoff.
  fi
  # `rc=0; run_job || rc=$?` — NOT `run_job; rc=$?`: under `set -e` a bare `run_job` returning non-zero
  # aborts the shell before rc is read, which would make the entire backoff ladder below dead code and
  # silently reinstate the 10s token-mint storm. The `|| ` puts run_job in a condition context (set -e
  # exempt) AND captures its code.
  local rc=0
  run_job || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$FAIL_STATE"
    exit 0
  fi
  # rc==2 (empty token — gh auth/keychain not ready) and rc==1 (job failed) BOTH fall through to the
  # backoff below. A permanent auth failure would otherwise hot-loop `POST .../registration-token`
  # every ~10s under KeepAlive (hammering a rate-limited endpoint); backing off protects it, and a
  # transient lock that clears just costs one backoff cycle before the next attempt succeeds and resets.
  # rc==1 → also distinguish a real JOB failure from an infra blip that struck AFTER the gate (colima
  # flap mid-docker-run). Re-probe: if infra is no longer healthy, it was infra — relaunch without
  # charging the backoff counter. (rc==2 with docker still up correctly falls through to backoff.)
  if ! wait_for_docker; then
    echo "[sandbox] failure coincided with infra going unready — relaunching without backoff" >&2
    exit 1
  fi
  # Real job failure with healthy infra → a token was minted. Back off exponentially (capped) before
  # exiting so KeepAlive's relaunch cadence — and the token-mint rate — grows instead of a fixed 10s.
  local n=0 backoff i
  # [ -f ]-GUARD the read: on the FIRST failure FAIL_STATE doesn't exist, and a failed `<` redirection
  # under set -e aborts the shell BEFORE the counter is written (verified on bash 3.2 AND 5.x) — which
  # would pin backoff at BASE forever and reinstate the token storm. Guarding + sanitizing the digits
  # makes the read total: no missing file, no corrupt content, can abort it.
  [ -f "$FAIL_STATE" ] && { n=$(tr -cd '0-9' < "$FAIL_STATE" 2>/dev/null) || n=0; }
  n=$(( ${n:-0} + 1 ))
  echo "$n" > "$FAIL_STATE" 2>/dev/null || true
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
