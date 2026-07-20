# HEARTBEAT — the arena's pulse

`triage.yml` is the arena's **reactive** half: a human files an issue, the rivals build it. The
heartbeat is the **generative** half. Once a day the arena wakes, looks at what it can do and what's
undone, recombines that into work it *chose*, tempers the design, and files its own issue.

That is the whole difference between a build-bot and something with an agenda. A build-bot only moves
when fed. A machine with a heartbeat wakes, looks at itself, and decides what's worth building.

```
   heartbeat ──▶ issue ──▶ ① ASCEND ──▶ ② FORGE ──▶ ③ CAGE-MATCH ──▶ ④ SPIRAL ──▶ merge (you)
   (self-fed)   (agenda)   heat in       work         demon sorts       heat out
```

## What one pulse does

`arena/heartbeat.mjs`, run by `.github/workflows/heartbeat.yml` on a daily schedule (and on manual
`workflow_dispatch`):

1. **Gather substrate** — the arena's own capabilities (README, PIPELINE, the four reviewer personas,
   the allowlist), its open backlog, and the org's repos. All read from durable sources, never guessed.
2. **Anti-stack guard** — if a prior self-filed issue (label `arena:heartbeat`) is still open, stay
   silent. **At most one self-generated issue is ever in flight**, so the pulse can never flood the
   build loop, even once armed.
3. **Think** — run Claude headless through `arena/heartbeat.prompt.md`, which drives three of the
   lab author's own skills in sequence:
   - **`/recombine`** — find the third thing latent between two of the arena's capabilities (anchor +
     preserved seam + subtraction). Not a generic feature request — a recombination of what the arena
     already *is*.
   - **`/ascend`** — select the most *alive* candidate: the one that makes the arena more self-sustaining,
     more itself. Aliveness over tidiness.
   - **Temper** (from `/crucible`) — attack the pick: kill the degenerate reading, check impact honestly,
     confirm it's buildable as **one PR by one agent**, and confirm it's safe by construction. Temper is
     a filter, not a formality — **most pulses should end in silence.**
4. **Act** — file one battle-tested issue (labeled `arena:heartbeat`), or log why it stayed silent.
   Filing **fails closed**: any unparseable or incomplete decision becomes silence, never a malformed issue.

## Caged by default — and how it's armed

The pulse is deliberately **disarmed** until a human arms it, following the repo's own trust rule
(*"trust is granted by merge, never by issue"* — `allowlist.txt`):

- The self-filed issue is authored by the default `github-actions[bot]`, which is **not in
  `allowlist.txt`**. So `triage.yml`'s gate routes it to the inert *propose* path — the issue is fully
  visible, but it **cannot trigger a privileged build.** You read the arena's self-chosen agenda and
  judge its taste, risk-free.
- GitHub also does not re-trigger workflows for events raised by the default token, so a caged pulse is
  doubly inert on the build side.

**To arm it** (a separate, deliberate PR — the narrow escalation channel):

1. Give the arena a bot identity (a GitHub App like the dreaming-repo's Flux, or a scoped PAT) and file
   the pulse's issues with **that** token instead of the default one.
2. Add that bot login to `allowlist.txt` in a gated PR to `main`. The moment you merge it, the same
   pulse's issues begin routing to the privileged build path and the arena starts building its own agenda.

Until both are done, the heartbeat proposes; it never builds or merges. Arming is intentionally two
commits away from the pulse itself.

## Testing it

```sh
# Pure-read dry run — gathers real substrate, runs the taste engine, prints the decision, files nothing:
HEARTBEAT_DRY_RUN=1 node arena/heartbeat.mjs
```

Requires `gh` (authed) and `claude` (Claude Code, authed via `CLAUDE_CODE_OAUTH_TOKEN`).
