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
# Dry run: report the fast-forward + relaunch/reap decisions WITHOUT changing the running system — no
# ff of the worktree, no kickstart, no container reap, no runner de-registration. It DOES still `git
# fetch` (updates the local origin/main tracking ref — a read of the remote, not a change to the
# worktree or any service), which is how it detects and reports drift. Any non-empty value enables it.
DRYRUN="${ARENA_AUTOPULL_DRYRUN:-}"

# SCOPE — SINGLE-HOST ASSUMPTION (Carnot cage-match, named constraint): runner_state selects GitHub
# runners repo-wide by the `sandbox`/`privileged` LABEL, which is not a per-host identity. On this
# arena's single self-hosted box that is exactly "this host's runners", but if a second host ever
# registers a runner with the same label, this daemon could de-register it or let its busy state veto a
# relaunch here. Multi-host requires a stable per-host label to filter on — tracked as a follow-up, not
# built here (this PR's scope is the single-box merge→run gap).

# kind : github-runner-label : launchd-label  (container label is always arena-runner=<kind>)
RUNNERS=(
  "sandbox:sandbox:com.daemon-engine.arena-sandbox"
  "privileged:privileged:com.daemon-engine.arena-privileged"
)

log() { echo "[autopull] $*" >&2; }

command -v git >/dev/null   || { log "git not on PATH — exiting"; exit 1; }
command -v gh >/dev/null    || { log "gh not on PATH — exiting"; exit 1; }
command -v docker >/dev/null|| { log "docker not on PATH — exiting"; exit 1; }

# Portable command bounding. GNU `timeout` is NOT on stock macOS — it ships as `gtimeout` via
# coreutils. A bounded network call is REQUIRED, not optional: launchd will not overlap ticks for the
# same label, so an UNBOUNDED hung `git fetch`/`gh api` freezes merge→run integrity indefinitely — a
# dead engine that merely LOOKS alive (Kelvin: "a fuse designed not to blow"). So we REQUIRE a timeout
# command and fail-CLOSED-LOUD if absent (every tick logs + exits non-zero, visible in the log) rather
# than run unbounded-and-frozen. `brew install coreutils` provides `gtimeout`.
TIMEOUT_CMD="$(command -v timeout || command -v gtimeout || true)"
[ -n "$TIMEOUT_CMD" ] || { log "FATAL: no timeout/gtimeout on PATH — refusing to run network calls unbounded (they would freeze the daemon under launchd's no-overlap). Install: brew install coreutils"; exit 1; }
bounded() { "$TIMEOUT_CMD" "$@"; }   # bounded <seconds> <cmd...>

# The deploy worktree must exist and be a LINKED worktree before we touch it (a linked worktree's .git
# is a FILE, not a dir — matches install-launchd.sh's identity rigor rather than accepting any git
# checkout; Kelvin: the daemon's guard must be isomorphic to the installer's). install-launchd.sh
# creates it and validated full repo-ownership at install; here we fail-closed on "not a linked
# worktree" rather than fall back to some other tree.
[ -f "$DEPLOY_ROOT/.git" ] && git -C "$DEPLOY_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  log "deploy worktree $DEPLOY_ROOT is not a linked git worktree (.git must be a file) — run install-launchd.sh first; exiting"
  exit 1
}

# --- 1. Fetch + detect drift -----------------------------------------------------------------------
# `timeout` bounds every network call: launchd will not overlap ticks for the same label, so a hung
# TLS fetch/API call would otherwise FREEZE merge→run integrity until the socket dies (Tesla). 60s for
# fetch (can be a real pull), 30s for the runner-state API below.
bounded 60 git -C "$DEPLOY_ROOT" fetch --quiet origin main 2>/dev/null || { log "fetch failed/timed out (network?) — exiting, will retry next tick"; exit 0; }
LOCAL="$(git -C "$DEPLOY_ROOT" rev-parse HEAD 2>/dev/null || true)"
REMOTE="$(git -C "$DEPLOY_ROOT" rev-parse origin/main 2>/dev/null || true)"
[ -n "$LOCAL" ] && [ -n "$REMOTE" ] || { log "could not resolve HEAD/origin/main — exiting"; exit 1; }
if [ "$LOCAL" = "$REMOTE" ]; then
  # Common case — no drift. Silent-ish (one line so a tail shows the daemon is alive).
  log "up to date @ ${LOCAL:0:7}"
  exit 0
fi

# --- 2. Fast-forward the deploy worktree (ff-only; fail-CLOSED on divergence) -----------------------
# NOTE (why fast-forwarding the tree that contains THIS running script is safe): `git merge --ff-only`
# writes each changed file to a NEW inode and renames it into place (verified: inode changes across an
# ff). A running bash holds the OLD inode's fd and keeps reading the original bytes to completion, so
# this process finishes on pre-merge code and the NEXT StartInterval tick runs the merged script. Do
# NOT "fix" this into a two-stage launcher on a self-modification worry — the atomic-rename guarantee
# already covers it (a Carnot cage-match finding, verified and rejected).
# --is-ancestor guards against a diverged deploy tree (should be impossible — nobody commits there —
# but if it happens, a non-ff merge would rewrite/conflict; refuse and surface it instead).
if ! git -C "$DEPLOY_ROOT" merge-base --is-ancestor "$LOCAL" "$REMOTE"; then
  log "⚠ deploy worktree @ ${LOCAL:0:7} is NOT an ancestor of origin/main @ ${REMOTE:0:7} — refusing non-ff; resolve by hand"
  exit 1
fi
if [ -n "$DRYRUN" ]; then
  log "[dry-run] would fast-forward deploy worktree ${LOCAL:0:7} → ${REMOTE:0:7}"
else
  # Capture stderr on failure — divergence is pre-checked above, but permissions/corruption can still
  # fail here and must be legible, not swallowed into /dev/null (Kelvin).
  if ! _ffout="$(git -C "$DEPLOY_ROOT" merge --ff-only origin/main 2>&1)"; then
    log "ff-only merge failed unexpectedly — exiting. git said: $_ffout"; exit 1
  fi
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
  bounded 30 gh api --paginate "repos/$REPO/actions/runners" \
    -q ".runners[] | select(any(.labels[]; .name == \"$1\")) | \"\(.id) \(.busy)\""
}

# De-register a set of IDLE runner ids from GitHub, and VERIFY each is actually gone. Safe even next to
# a busy sibling: GitHub refuses to DELETE a runner currently running a job (422), so a mis-identified
# id can never drop a live job; this touches only registrations, never containers. The DELETE is
# LOAD-BEARING — the whole "made unschedulable before we leave it alone" invariant rests on it — so we
# do NOT swallow its outcome (Carnot HIGH: `|| true` turned a failed DELETE into a false success).
# We verify the COUNTERPARTY-OBSERVABLE outcome (a GET returning 404 = truly gone) rather than trusting
# the DELETE exit code, which also can't tell "deleted" from "404 already gone". Returns non-zero if
# ANY id could not be confirmed removed, so callers can fail-visible.
deregister_idle() {   # $@ = runner ids; return 0 iff every id is confirmed gone
  local rid rc=0
  for rid in "$@"; do
    bounded 30 gh api -X DELETE "repos/$REPO/actions/runners/$rid" >/dev/null 2>&1 || true
    # Invariant check: the runner must no longer exist. A GET that still succeeds means it is STILL
    # registered and schedulable (DELETE failed on auth/network/perm) — surface it loudly.
    if bounded 30 gh api "repos/$REPO/actions/runners/$rid" >/dev/null 2>&1; then
      log "WARN: idle runner $rid STILL registered after de-register attempt (auth/network/perm?) — it may schedule on OLD code; will retry next tick"
      rc=1
    fi
  done
  return "$rc"
}

# True (exit 0) if any row in a roster text ("<id> <busy>" lines) is busy. Named for legibility so the
# set-e-safe re-check reads plainly rather than as an inline pipe (Kelvin).
rows_have_busy() { printf '%s\n' "$1" | grep -q ' true$'; }

for spec in "${RUNNERS[@]}"; do
  IFS=: read -r kind ghlabel label <<<"$spec"

  # Capture the CURRENT (stale) container ids BEFORE relaunch so we reap exactly these, never the
  # fresh container the relaunch creates.
  old_containers="$(docker ps -q --filter "label=arena-runner=$kind" 2>/dev/null || true)"

  # Read the FULL roster. A failed/partial read is fail-CLOSED: skip this kind entirely (Tesla — a
  # partial page is not a fail-closed read).
  # MUST use `if ! rows=$(...)`: under `set -euo pipefail` a bare `rows=$(runner_state)` that fails
  # ABORTS the whole script before a following `rs_rc=$?` can be read, making the fail-closed branch
  # dead code (Carnot + Tesla HIGH — the classic set-e command-sub trap this subsystem keeps hitting).
  # The `if` puts the substitution in a set-e-exempt condition context.
  if ! rows="$(runner_state "$ghlabel")"; then
    log "$kind: runner-state query failed (network/API/timeout) — skipping this tick (fail-closed)"
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
  # an orphan's by label alone. Honest residual (Tesla): a de-registered idle runner's CONTAINER is now
  # INERT (unschedulable — it can never pick up a job), but it is not reaped here and there is no reap
  # on a no-drift tick, so an inert container can linger until the next drift-relaunch of this kind or a
  # reinstall. That is a bounded resource leak, never a stale-code-execution path (the security-critical
  # invariant — no runner runs jobs on old code — holds the instant we de-register).
  if [ "$busy_any" = "1" ]; then
    if [ -z "${idle_ids// /}" ]; then
      log "$kind: a runner is BUSY, no idle registrations — self-heals on job completion"
    elif [ -n "$DRYRUN" ]; then
      log "[dry-run] $kind: BUSY sibling — would de-register idle registration(s) [${idle_ids# }] (no relaunch, no container reap)"
    elif deregister_idle $idle_ids; then
      log "$kind: BUSY sibling — not relaunching; de-registered stale idle registration(s) so they cannot schedule on old code"
    else
      # deregister_idle already logged which id(s) survived. Do NOT claim success — the stale runner may
      # still be schedulable on old code; the next tick retries (still drifted / still idle).
      log "$kind: BUSY sibling — de-registration INCOMPLETE (see WARN above); will retry next tick"
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
  # Same set-e-safe form as above — a bare `recheck=$(...)` on failure would abort the script, not skip.
  if ! recheck="$(runner_state "$ghlabel")"; then
    log "$kind: re-check query failed just before relaunch — skipping this tick (fail-closed)"
    continue
  fi
  if rows_have_busy "$recheck"; then
    # A sibling went busy since the first read: do NOT kickstart (never interrupt) — but still
    # de-register the confirmed-idle stale registration(s), exactly as the busy-branch does, so they
    # can't schedule on old code during the one-tick window (Carnot MEDIUM: the pre-kickstart branch
    # used to skip that cleanup). deregister_idle 422-tolerates a now-busy id and verifies each is gone.
    if [ -n "$DRYRUN" ]; then
      log "[dry-run] $kind: became BUSY at re-check — would de-register idle [${idle_ids# }], no kickstart"
    elif deregister_idle $idle_ids; then
      log "$kind: became BUSY at re-check — not kickstarting; de-registered stale idle registration(s)"
    else
      log "$kind: became BUSY at re-check — de-register incomplete (see WARN); will retry next tick"
    fi
    continue
  fi
  log "$kind: idle & drifted — relaunching onto merged code"
  # ORDER MATTERS (Tesla): de-register the idle runner(s) BEFORE the hard kickstart. `kickstart -k`
  # SIGKILLs the old process and orphans its --rm container while it is STILL REGISTERED and
  # schedulable — a job could land on that pre-relaunch container in the window between kickstart and
  # deregister, then die under `docker rm -f`. De-registering first makes the old runner unschedulable
  # before we kill it (GitHub 422-protects a true busy mis-id), closing the post-kickstart orphan window.
  # A failed de-register here is backstopped by the kickstart below: SIGKILL disconnects the old
  # ephemeral runner, and GitHub auto-removes an ephemeral runner on disconnect — so even an
  # un-DELETE-able registration goes offline seconds later. deregister_idle already logged any failure;
  # we proceed (unlike the busy branch, which has no kill to fall back on).
  deregister_idle $idle_ids || log "$kind: de-register incomplete — relying on kickstart-disconnect to offline the stale ephemeral runner"
  # Do NOT swallow kickstart's stderr — a novel launchd failure must be legible in the log (Kelvin).
  launchctl kickstart -k "$DOMAIN/$label" || { log "$kind: kickstart failed (see stderr above) — will retry next tick"; continue; }
  # Reap the OLD container (launchd's SIGKILL skips docker --rm cleanup, orphaning it — observed). The
  # new container the relaunch creates has a distinct id, so reaping the pre-captured old ids never
  # touches it.
  for c in $old_containers; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  log "$kind: de-registered stale runner(s), relaunched, reaped stale container(s)"
done

exit 0
