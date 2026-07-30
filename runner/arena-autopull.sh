#!/usr/bin/env bash
# arena-autopull — the merge→run integrity daemon.
#
# WHY THIS EXISTS: the launchd sandbox/privileged runners exec run-sandbox.sh / run-privileged.sh
# from a git working tree. "Merge to main" does NOT imply "the running process executes the merged
# code" — an idle ephemeral runner blocks in ./run.sh indefinitely, so the oneshot+KeepAlive
# auto-reload never cycles and the merged script never activates (observed: a runner Up 8 days on a
# pre-merge script). This daemon makes activation DETERMINISTIC: on each tick it fast-forwards the
# dedicated DEPLOY worktree to origin/main and relaunches any IDLE runner onto the merged code.
#
# KEY DESIGN — only ever touch IDLE runners:
#   * A BUSY runner self-heals for free: it finishes its one ephemeral job, the process exits, and
#     launchd relaunches it onto the (already fast-forwarded) merged script. So we NEVER interrupt a
#     live build — we skip a busy runner this tick and it heals on its own job boundary.
#   * Idle detection is AUTHORITATIVE: GitHub's own `busy` field on the runner, not a guess from
#     container internals. Fail-CLOSED: if we cannot determine busy-state, treat as busy → skip.
#
# Supervision: launchd StartInterval (~60s) is the loop; a single run of this script is one tick and
# exits. launchd will not start a second copy while one is running (same label) → self-serializing.
#
# Auth/tools: runs on the runner host; uses gh (host auth), git, docker, launchctl. PATH is set by
# the plist (launchd agents get a minimal PATH that excludes /opt/homebrew/bin).
set -euo pipefail

REPO="daemon-engine-labs/the-building-repo"
DEPLOY_ROOT="${ARENA_DEPLOY_ROOT:-$HOME/.arena-deploy}"
UID_NUM="$(id -u)"
DOMAIN="gui/$UID_NUM"
# Dry run: report the fast-forward + relaunch decisions WITHOUT mutating anything (no ff, no kickstart,
# no reap). Useful to preview what a tick would do on a live box, and to verify the daemon's logic in
# isolation. Any non-empty value enables it.
DRYRUN="${ARENA_AUTOPULL_DRYRUN:-}"

# kind : github-runner-label : launchd-label  (container label is always arena-runner=<kind>)
RUNNERS=(
  "sandbox:sandbox:com.daemon-engine.arena-sandbox"
  "privileged:privileged:com.daemon-engine.arena-privileged"
)

log() { echo "[autopull] $*" >&2; }

command -v git >/dev/null   || { log "git not on PATH — exiting"; exit 1; }
command -v gh >/dev/null    || { log "gh not on PATH — exiting"; exit 1; }
command -v docker >/dev/null|| { log "docker not on PATH — exiting"; exit 1; }

# The deploy worktree must exist and be a real worktree before we touch it. install-launchd.sh
# creates it; if it is missing we do nothing (fail-closed — never fall back to some other tree).
[ -d "$DEPLOY_ROOT/.git" ] || git -C "$DEPLOY_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
  log "deploy worktree $DEPLOY_ROOT is not a git worktree — run install-launchd.sh first; exiting"
  exit 1
}

# --- 1. Fetch + detect drift -----------------------------------------------------------------------
git -C "$DEPLOY_ROOT" fetch --quiet origin main 2>/dev/null || { log "fetch failed (network?) — exiting, will retry next tick"; exit 0; }
LOCAL="$(git -C "$DEPLOY_ROOT" rev-parse HEAD 2>/dev/null || true)"
REMOTE="$(git -C "$DEPLOY_ROOT" rev-parse origin/main 2>/dev/null || true)"
[ -n "$LOCAL" ] && [ -n "$REMOTE" ] || { log "could not resolve HEAD/origin/main — exiting"; exit 1; }
if [ "$LOCAL" = "$REMOTE" ]; then
  # Common case — no drift. Silent-ish (one line so a tail shows the daemon is alive).
  log "up to date @ ${LOCAL:0:7}"
  exit 0
fi

# --- 2. Fast-forward the deploy worktree (ff-only; fail-CLOSED on divergence) -----------------------
# --is-ancestor guards against a diverged deploy tree (should be impossible — nobody commits there —
# but if it happens, a non-ff merge would rewrite/conflict; refuse and surface it instead).
if ! git -C "$DEPLOY_ROOT" merge-base --is-ancestor "$LOCAL" "$REMOTE"; then
  log "⚠ deploy worktree @ ${LOCAL:0:7} is NOT an ancestor of origin/main @ ${REMOTE:0:7} — refusing non-ff; resolve by hand"
  exit 1
fi
if [ -n "$DRYRUN" ]; then
  log "[dry-run] would fast-forward deploy worktree ${LOCAL:0:7} → ${REMOTE:0:7}"
else
  git -C "$DEPLOY_ROOT" merge --ff-only origin/main >/dev/null 2>&1 || { log "ff-only merge failed unexpectedly — exiting"; exit 1; }
  log "fast-forwarded deploy worktree ${LOCAL:0:7} → ${REMOTE:0:7}"
fi

# --- 3. Relaunch each IDLE runner onto the merged script; leave busy ones to self-heal --------------
# Query GitHub for this kind's runner rows (a self-hosted runner appears once with all its labels).
# We want: does a runner with label <ghlabel> exist, and is it busy? jq-free parse via gh -q.
runner_state() {   # prints "<id> <busy>" lines for runners carrying the given label
  local ghlabel="$1"
  gh api "repos/$REPO/actions/runners" \
    -q ".runners[] | select(any(.labels[]; .name == \"$ghlabel\")) | \"\(.id) \(.busy)\"" 2>/dev/null || true
}

for spec in "${RUNNERS[@]}"; do
  IFS=: read -r kind ghlabel label <<<"$spec"

  # Capture the CURRENT (stale) container ids BEFORE relaunch so we reap exactly these, never the
  # fresh container the relaunch creates.
  old_containers="$(docker ps -q --filter "label=arena-runner=$kind" 2>/dev/null || true)"

  # Decide from GitHub's authoritative busy field. Fail-CLOSED: any parse trouble → treat as busy.
  busy_any=0 idle_ids=""
  while read -r rid rbusy; do
    [ -n "$rid" ] || continue
    if [ "$rbusy" = "false" ]; then
      idle_ids="$idle_ids $rid"
    else
      busy_any=1
    fi
  done <<<"$(runner_state "$ghlabel")"

  if [ "$busy_any" = "1" ]; then
    log "$kind: a runner is BUSY — skipping relaunch this tick (it self-heals on job completion)"
    continue
  fi
  if [ -z "${idle_ids// /}" ]; then
    log "$kind: no idle runner registered yet — launchd will bring one up on merged code; nothing to do"
    continue
  fi

  # Idle + drifted → force a fresh relaunch onto the merged script.
  if [ -n "$DRYRUN" ]; then
    log "[dry-run] $kind: idle & drifted — would relaunch (kickstart $label), reap container(s) [$old_containers] + runner id(s) [${idle_ids# }]"
    continue
  fi
  # TOCTOU narrowing: re-check busy immediately before the HARD relaunch. A job can be assigned in the
  # seconds since the first query; kickstart -k would SIGTERM it mid-run. This can't be fully closed
  # without cooperative draining, but the re-check shrinks the window to sub-second. Named tradeoff:
  # the residual worst case is one interrupted job on a merge tick, surfaced by GitHub as a re-runnable
  # failed run — never a silent corruption, and only on the rare tick where a merge and a job-assignment
  # collide on a previously-idle runner.
  if runner_state "$ghlabel" | grep -q ' true$'; then
    log "$kind: became BUSY just before relaunch — skipping this tick (will heal on its job boundary)"
    continue
  fi
  log "$kind: idle & drifted — relaunching onto merged code"
  launchctl kickstart -k "$DOMAIN/$label" 2>/dev/null || { log "$kind: kickstart failed — will retry next tick"; continue; }

  # Reap the OLD container (launchd's SIGKILL skips docker --rm cleanup, orphaning it — observed) and
  # the OLD idle GitHub registrations, so exactly one live pair per kind remains. Never touch the new
  # container/runner the relaunch just created (we only reap the pre-relaunch captures).
  for c in $old_containers; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  for rid in $idle_ids; do gh api -X DELETE "repos/$REPO/actions/runners/$rid" >/dev/null 2>&1 || true; done
  log "$kind: relaunched; reaped stale container(s) + registration(s)"
done

exit 0
