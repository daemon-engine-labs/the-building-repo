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
# `timeout` bounds every network call: launchd will not overlap ticks for the same label, so a hung
# TLS fetch/API call would otherwise FREEZE merge→run integrity until the socket dies (Tesla). 60s for
# fetch (can be a real pull), 30s for the runner-state API below.
timeout 60 git -C "$DEPLOY_ROOT" fetch --quiet origin main 2>/dev/null || { log "fetch failed/timed out (network?) — exiting, will retry next tick"; exit 0; }
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
# runner_state prints "<id> <busy>" lines for every runner carrying the label, and its EXIT STATUS is
# load-bearing: a non-zero return (network / API / timeout) means "I could not read the full roster",
# which the caller treats as fail-CLOSED (skip). `--paginate` is REQUIRED for completeness: the default
# page is ~30 rows, and the SIGKILL-orphan pathology this daemon exists to clean is exactly how the
# roster swells past one page — deciding busy on page 1 alone could miss a busy=true on page 2 and
# fail-OPEN into a hard relaunch (Tesla). Fail-closed means COMPLETE, not merely non-empty
# (concept_default_deny_completeness_on_hand_rolled_parsers). No `|| true`: the status must propagate.
runner_state() {   # $1=ghlabel; stdout = rows, exit status = did we read the whole roster
  timeout 30 gh api --paginate "repos/$REPO/actions/runners" \
    -q ".runners[] | select(any(.labels[]; .name == \"$1\")) | \"\(.id) \(.busy)\""
}

# De-register a set of IDLE runner ids from GitHub. Safe even next to a busy sibling: GitHub refuses to
# DELETE a runner that is currently running a job (422), so a mis-identified id can never drop a live
# job; and this touches only registrations, never containers. Bounded by `timeout`.
deregister_idle() {   # $@ = runner ids
  local rid
  for rid in "$@"; do timeout 30 gh api -X DELETE "repos/$REPO/actions/runners/$rid" >/dev/null 2>&1 || true; done
}

for spec in "${RUNNERS[@]}"; do
  IFS=: read -r kind ghlabel label <<<"$spec"

  # Capture the CURRENT (stale) container ids BEFORE relaunch so we reap exactly these, never the
  # fresh container the relaunch creates.
  old_containers="$(docker ps -q --filter "label=arena-runner=$kind" 2>/dev/null || true)"

  # Read the FULL roster. A failed/partial read is fail-CLOSED: skip this kind entirely (Tesla — a
  # partial page is not a fail-closed read).
  rows="$(runner_state "$ghlabel")"; rs_rc=$?
  if [ "$rs_rc" -ne 0 ]; then
    log "$kind: runner-state query failed (rc=$rs_rc — network/API/timeout) — skipping this tick (fail-closed)"
    continue
  fi

  busy_any=0 idle_ids=""
  while read -r rid rbusy; do
    [ -n "$rid" ] || continue
    if [ "$rbusy" = "false" ]; then idle_ids="$idle_ids $rid"; else busy_any=1; fi
  done <<<"$rows"

  # A BUSY sibling means we must NOT kickstart (never interrupt a live build) — but a stale IDLE
  # registration is schedulable on old code and IS the failure this daemon prevents, so de-register it
  # regardless of the busy sibling (Carnot HIGH — a label-wide busy veto left idle orphans online). We
  # deliberately do NOT touch containers here: we cannot cheaply tell the busy runner's container from
  # an orphan's by label alone, and a de-registered idle runner is already unschedulable, so its
  # container is inert until the next no-busy tick reaps it.
  if [ "$busy_any" = "1" ]; then
    if [ -z "${idle_ids// /}" ]; then
      log "$kind: a runner is BUSY, no idle registrations — self-heals on job completion"
    elif [ -n "$DRYRUN" ]; then
      log "[dry-run] $kind: BUSY sibling — would de-register idle registration(s) [${idle_ids# }] (no relaunch, no container reap)"
    else
      deregister_idle $idle_ids
      log "$kind: BUSY sibling — not relaunching; de-registered stale idle registration(s) so they cannot schedule on old code"
    fi
    continue
  fi

  if [ -z "${idle_ids// /}" ]; then
    log "$kind: no idle runner registered yet — launchd will bring one up on merged code; nothing to do"
    continue
  fi

  # Idle + not busy + drifted → force a fresh relaunch onto the merged script.
  if [ -n "$DRYRUN" ]; then
    log "[dry-run] $kind: idle & drifted — would relaunch (kickstart $label), reap container(s) [$old_containers] + runner id(s) [${idle_ids# }]"
    continue
  fi
  # TOCTOU narrowing: re-check busy immediately before the HARD relaunch. A job can be assigned in the
  # seconds since the first query; kickstart -k would SIGTERM it mid-run. This can't be fully closed
  # without cooperative draining, but the re-check shrinks the window to sub-second. Named tradeoff:
  # the residual worst case is one interrupted job on a merge tick, surfaced by GitHub as a re-runnable
  # failed run — never silent corruption. A FAILED re-check is also fail-closed (skip).
  recheck="$(runner_state "$ghlabel")"; rc_rc=$?
  if [ "$rc_rc" -ne 0 ] || printf '%s\n' "$recheck" | grep -q ' true$'; then
    log "$kind: became BUSY or re-check failed just before relaunch — skipping this tick (will heal on its job boundary)"
    continue
  fi
  log "$kind: idle & drifted — relaunching onto merged code"
  # Do NOT swallow kickstart's stderr — a novel launchd failure must be legible in the log (Kelvin).
  launchctl kickstart -k "$DOMAIN/$label" || { log "$kind: kickstart failed (see stderr above) — will retry next tick"; continue; }

  # Reap the OLD container (launchd's SIGKILL skips docker --rm cleanup, orphaning it — observed) and
  # the OLD idle GitHub registrations, so exactly one live pair per kind remains. Never touch the new
  # container/runner the relaunch just created (we only reap the pre-relaunch captures).
  for c in $old_containers; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  deregister_idle $idle_ids
  log "$kind: relaunched; reaped stale container(s) + registration(s)"
done

exit 0
