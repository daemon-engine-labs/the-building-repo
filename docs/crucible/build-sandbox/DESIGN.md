# DESIGN — Safe untrusted `build-sandbox` propose path

## Problem

`triage.yml` gates on the issue author's GitHub login. Allowlisted (`nickmeinhold`) →
`build-privileged` (real secrets, forge → PR → self-review; **already working**). Everyone else,
including the heartbeat bot → `build-sandbox`, **a no-op placeholder** that runs only an isolation
proof. So no non-human / non-allowlisted issue ever gets built. We must complete `build-sandbox`
safely.

The hard coupling: **an LLM build needs a credential, but the sandbox is defined as the place
credentials must not exist** (`egress-allowlist.txt:14` — "sandbox holds no secrets"). A Claude token
placed on the sandbox is exfiltratable through a **network-independent** channel the egress wall
cannot see:

```
hostile issue text → prompt-injects the agent → "write $CLAUDE_CODE_OAUTH_TOKEN to a file"
  → token lands in the diff → diff is uploaded as the artifact → artifact becomes the PR body
```

The egress wall blocks the token from being POSTed anywhere, but the artifact/PR is a *legitimate*
outbound channel, so the wall never inspects it.

## The decomposition fork (this is the crux)

**Decomposition A — token on the sandbox + secret-scan gate (the shape handed in).**
Put a narrow quota-only Claude token in the sandbox container; close the exfil channel with a
publish-side secret-scan that refuses to open a PR if the patch contains token-shaped content.

- *Fatal smell:* the secret-scan is a **denylist racing the attacker's encoding creativity**. An
  injected agent can base64 / rot13 / chunk / whitespace-interleave the token to slip any pattern
  match. This is *guard-the-window*, and the window can't be fully closed by inspection. It is
  exactly the "Nth defensive guard = architecture smell" pattern: the scan exists only because the
  credential is somewhere it shouldn't be.

**Decomposition B — no credential on the sandbox at all (auth-injecting egress proxy). ← PROPOSED.**
The sandbox agent points at a local proxy (`ANTHROPIC_BASE_URL=http://arena-auth:PORT`) inside the
`arena-internal` docker network. The agent holds a **dummy** auth token. The proxy — running on the
*egress* side, not the sandbox — strips the incoming Authorization header and injects the **real**
OAuth token on the way out to `https://api.anthropic.com`. The token lives in the proxy, never in the
sandbox's env or filesystem.

- The `claude→proxy` hop is plaintext HTTP on an isolated internal docker network (no TLS MITM
  needed; the network is not exposed).
- Prompt-injection "print your token" yields **nothing** — there is no token on the runner to print.
- The entire injection→file→diff→artifact channel is **moot for the credential**: there is no
  credential present. The residual risk collapses from "credential exfil + malicious code" to just
  "malicious code," which the existing human-merge + CODEOWNERS gate already governs.

**This is remove-the-coupling, not guard-the-window.** The secret-scan (A's primary defense) becomes
at most defense-in-depth in B, never load-bearing. **B is the design.** A is recorded as the rejected
alternative.

## Proposed shape (Decomposition B)

Three components:

1. **`arena-auth` proxy** (new, egress-side container). A tiny forward proxy for `api.anthropic.com`
   only. Holds the real `CLAUDE_CODE_OAUTH_TOKEN` (from the runner box env / a Worker secret, NOT a
   GitHub Actions secret). Injects `Authorization: Bearer <real>` on outbound; forwards nothing else.
   Runs beside `tinyproxy` on the egress side; lifetime = egress agent lifetime.

2. **`build-sandbox` job** (complete the placeholder). After the isolation proof:
   `AGENT=claude MODE=propose node arena/run.mjs` with `ANTHROPIC_BASE_URL` → the auth proxy and a
   dummy token. Issue title/body/number via **env, never interpolated** (matches privileged path).
   Then `git diff` → upload as an artifact. **No repo-write token; job-level `permissions` stay at
   the workflow default (`contents: read`).**

3. **`publish.yml` publisher** (new, `workflow_run`-triggered on `build-sandbox` completing). Runs
   from the **default branch** (workflow_run always does — un-overridable by a PR). Downloads the
   patch artifact, **applies it as text** (`git apply`, never executes), opens a PR with a bot token,
   human reviews. Holds **only** a PR-scoped token — **no provider secrets, no OAuth, no spend**
   (it runs no agent). Rejects/loud-flags patches touching privileged paths (`.github/`,
   `allowlist.txt`, `CODEOWNERS`, `arena/spend-requests/**`).

## Build order (core-first, each step independently useful)

1. **Spike: confirm `ANTHROPIC_BASE_URL` + dummy-token works with `claude -p`** against a local
   header-injecting proxy. This is the load-bearing premise — verify before building on it. If it
   fails, the whole of B is invalid and we fall back to A (or leave sandbox inert). *Independently
   useful:* proves/disproves the credential-off-runner pattern for the whole arena.
2. **`arena-auth` proxy** container + egress wiring + allowlist entry. *Independently useful:* the
   pattern is reusable for every future sandbox agent (codex/gemini/grok on the untrusted path).
3. **Complete `build-sandbox`** to run the agent through the proxy and upload the diff artifact.
   Still opens no PR — verify a diff artifact appears. *Independently useful:* proves the untrusted
   build runs credential-free.
4. **`publish.yml`** — artifact → patch-apply → PR, with the privileged-path patch guard. *This* is
   the step that makes #16 buildable end-to-end.

## Blast-radius & consent spine (cage before monster)

- **Owner of the injection surface:** the sandbox agent eats attacker-controlled issue text. Its
  blast radius under B is bounded to "produce a malicious diff," which cannot merge without a human
  + CODEOWNERS. No credential is reachable.
- **The `arena-auth` proxy is the new trust concentrator** — it holds the real token. It must be
  reachable ONLY from `arena-internal`, never from the public internet, and must forward ONLY to
  `api.anthropic.com` (its own tight allowlist). If the proxy is compromised, the token leaks — so
  the proxy is small, audited, and holds a **quota-only** token (no repo-write, no spend).
- **Re-entrancy:** opening a PR must not re-trigger a privileged build. `triage.yml` fires on
  `issues`, not `pull_request`, and there is no `pull_request`-triggered privileged workflow — so a
  bot-opened PR does not loop. (Verify no future workflow adds a `pull_request` privileged trigger.)
- **Trust is granted by merge, never by issue** — preserved: the untrusted path only ever *proposes*.

## Claims to falsify (hand these to the adversary)

1. **`claude -p` honors `ANTHROPIC_BASE_URL` and runs with a dummy `ANTHROPIC_AUTH_TOKEN` when a proxy
   injects the real one.** Not in `--help`; documented in Anthropic docs. If false, B is dead.
   (Sub-risk: OAuth tokens may be pinned to a TLS-verified host; if the CLI refuses a plaintext base
   URL, we need TLS termination on the proxy + CA trust in the sandbox image — more machinery.)
2. **A plaintext `claude→proxy` hop on `arena-internal` is acceptable.** The network is isolated and
   Nick-owned; the plaintext carries a dummy token only. If the internal network is shared with
   anything untrusted, this weakens.
3. **`git apply` of an attacker-influenced patch is safe as long as it isn't executed.** A patch can
   only modify files; the danger is a modified privileged file merged by an inattentive human. The
   patch-guard + CODEOWNERS is the defense. Is the guard's path list complete?
4. **The residual ("malicious code in a PR a human reviews") is genuinely covered by human-merge +
   CODEOWNERS.** Is a human reviewer a sufficient control against a subtly-malicious agent diff, or
   is that the same social-contract weakness the Spend Cage retro named?
5. **No other secret is present on the sandbox.** The isolation proof asserts empty GitHub Actions
   secrets, but does the runner *container image* or the box env leak anything (npm tokens, gh
   keychain) into the agent's reach?

## Rejected alternatives

- **A (token on sandbox + secret-scan):** guard-the-window; the scan is an evadable denylist. Kept
  only as optional defense-in-depth.
- **C (allowlist the heartbeat bot → privileged path):** grants the bot (fed attacker-controllable
  public issue text, per HEARTBEAT.md) the secret-bearing path. This is the exact injection surface
  the design exists to avoid. Rejected.
- **D (no LLM; deterministic/templated builds only):** defeats the purpose of an agent arena.
- **E (sandbox produces only a plan; a privileged agent builds it):** untrusted issue text drives a
  privileged agent — same injection surface as C. Rejected.

## TEMPER RESULTS (round 1 — 4-family strike, 2026-07-30)

**Verdict: REQUEST_CHANGES, unanimous** (Maxwell + Kelvin/Gemini + Carnot/GPT + Tesla/Grok;
Wu/Kimi quota-dead this cycle). **B is NOT invalidated** — all four affirm B's direction is correct
*over A* (remove-the-coupling beats guard-the-window). But the design as cast does **not** survive the
strike. The findings reshape the core invariant and surface a simpler decomposition. Folded back:

**T1 — THE KILLER (all four converge). B renames the secret; it does not remove it.** The invariant
"no credential on the sandbox → nothing to exfil" is FALSE. The proxy is an **unauthenticated spend
faucet**: any process on `arena-internal` that opens a socket to `arena-auth` gets full model spend.
The exfil story no longer even needs the token — hostile issue → agent curls the proxy in a maxed
completion loop → full Max-plan quota burn, and the egress wall cannot see "legitimate" Anthropic
traffic. If the proxy validates the dummy token, the dummy IS a shared spend-credential on the
sandbox — the secret renamed, not removed.
  - **Fold:** the real invariant is **"no *reusable credential material* on the sandbox"**, NOT "no
    credential." `arena-auth` is a **spend trust boundary**, not a vault. Requires: per-job caller
    auth (one-run nonce / per-job network namespace, NOT whole-of-`arena-internal`), a hard
    token/request **budget cap + kill switch**, response-header scrubbing, path/method allowlist to
    `api.anthropic.com` only. Named residual: **proxy or sandbox-network compromise = full quota
    burn** (bounded, not "no blast radius").

**T2 — the GitHub token is still on the closed channel (Carnot + Tesla).** `build-sandbox` does not
override job `permissions`, so it inherits the workflow default `issues: write` AND carries
`GITHUB_TOKEN` + `ACTIONS_RUNTIME_TOKEN` — all on the *identical* write-to-file→artifact→PR channel B
just closed for OAuth. Solving the demo vuln, missing the live one.
  - **Fold:** set `build-sandbox` `permissions: { contents: read }` explicitly (strip `issues:
    write`); document every unavoidable Actions token as a named, minimized capability.

**T3 — the patch guard is an incomplete denylist → privilege escalation delayed by one merge (all).**
The guard list (`.github/`, `allowlist.txt`, `CODEOWNERS`, `arena/spend-requests/**`) misses
`arena/run.mjs`, `agents/**`, `arena/agents.json`, `runner/**`, `.claude/settings.json`,
`package.json` scripts, Dockerfiles, lockfiles. A patch rewriting any of them, merged under review
fatigue, poisons the **next privileged build** which runs with the real token. `git apply` "never
executes" is true on the publish runner but false as a system property — **merge is the execution
scheduler for the next privileged job.**
  - **Fold:** invert to a **default-deny path allowlist** — untrusted artifacts may touch only
    *product* paths (an explicit allowlist), everything else rejected. Refuse symlinks, submodules,
    binary/large files, executable bits, lifecycle hooks. `git apply --check` in a clean worktree.
    CODEOWNERS is the backstop, not the primary control.

**T4 — the base-URL spike got sharper sub-falsifiers (Carnot + Tesla).** The premise is
*provisionally* supported by Anthropic's LLM-gateway docs (`ANTHROPIC_AUTH_TOKEN` beats
`CLAUDE_CODE_OAUTH_TOKEN` in precedence — the gateway pattern is first-party), but the *exact*
"proxy holds OAuth and rewrites Authorization" drawing is unproven, and **`ANTHROPIC_BASE_URL` may
still use a saved `~/.claude` login if present** → B silently collapses to token-on-sandbox unless
the runner image has an empty `~/.claude`. The spike must prove: `claude -p` with base-URL + dummy
`ANTHROPIC_AUTH_TOKEN`, **no `CLAUDE_CODE_OAUTH_TOKEN`, no `~/.claude/.credentials.json`**, completes
a real generation; and whether OAuth-subscription inject works or only an API key (`x-api-key`) does.

**T5 — human-merge + CODEOWNERS IS the Spend Cage social-contract residual, restated (Maxwell +
Carnot + Tesla).** Not a fresh mitigation — the same control the arena's own retro found collapses to
`enforce_admins:false`. Name it as the same known residual with the same lift condition.

**T6 — a simpler decomposition surfaced: F = consent-gated one-shot build (Carnot).** Inert-build
default + a human-applied `approve-untrusted-build` label that starts ONE bounded, proxy-backed run.
Preserves the heartbeat's self-generated agenda but moves the credentialed/spend capability behind
**explicit human consent** — dissolving most of the autonomy attack surface (T1's faucet only opens
on a human's click, not on any bot-authored issue). **Trade:** autonomy for safety.

**DECISION (Nick, 2026-07-30): B-hardened / full autonomy.** Keep the fully-autonomous path (any
bot/untrusted issue auto-builds — the arena stays self-sustaining), and pay for ALL FIVE temper fixes
(T1–T5) as build prerequisites. F is rejected: the heartbeat's self-generated agenda must not wait on
a human click. The standing spend faucet is accepted, hardened by T1's per-job auth + budget cap +
kill switch. This resolves the Blade fork.

## SPIKE RESULT (Step 0 — 2026-07-30): kill-switch GREEN on mechanism

Ran `claude -p` in an isolated empty `HOME`, `CLAUDE_CODE_OAUTH_TOKEN` unset, dummy
`ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL` → a local header-injecting proxy holding the real token.
- **claude honored `ANTHROPIC_BASE_URL`** and sent the request to the proxy.
- **claude sent the DUMMY token** as `Authorization: Bearer` (proxy log: `client-sent auth was: Bearer
  dummy-sk-…`) — no fallback to a saved login despite empty HOME. **Kills the T4 silent-fallback risk.**
- Proxy injected real OAuth Bearer + `anthropic-beta: oauth-2025-04-20` → upstream returned **429
  "your account's rate limit"**, NOT 401/403. An account-scoped 429 is only reachable post-auth →
  **OAuth-Bearer injection authenticates.** The circuit works.
- **Un-proven (bounded scope):** no 200 completion observed — blocked by the account's current rate
  limit (environmental, not a design flaw; same quota reality as issue #15). Steps 1-3 are quota-free
  infra and cleared to build; Step 4 live end-to-end verify waits on quota.
- Decision: OAuth-subscription inject works — no API-key path needed.

## STEP 2 SHIPPED — named residuals (cage-match PR #18, 3 rounds)

Step 2 (host-side nonce mint + `build-sandbox` job wiring + server-side TTL) shipped after a 4-family
cage-match (Wu quota-dead). Two residuals are ACCEPTED and NAMED, not silently absorbed:

- **Nonce-in-artifact.** The propose agent holds its nonce as `ANTHROPIC_AUTH_TOKEN` in env (by design),
  so a prompt-injected agent can write the nonce value into `proposed.patch` → the artifact. This is a
  manifestation of T1's already-accepted bounded residual: a leaked nonce is NOT a leaked token — it is
  budget-capped (≤ one job's requests/tokens), TTL-bounded (`NONCE_TTL_MS`, default 1h), and revoked at
  job end. Max exposure = `min(budget, TTL)`, and the window to use it closes at host revoke shortly after
  upload. **Lift condition:** Step 3's publisher MUST treat the patch as hostile (default-deny path
  allowlist) and never re-inject or log nonce-shaped strings. Tightening tracked as a data-plane
  self-revoke endpoint the job calls before capture (task) — would close the window fully.
- **Trapless death (SIGKILL/OOM/power-loss).** `run-sandbox.sh` revokes on EXIT/INT/TERM, but a SIGKILL
  skips the trap; the nonce then lives until the server TTL. Bounded by `min(budget, NONCE_TTL_MS)` — ops
  must keep the TTL ≤ the acceptable leak window. This is the fail-closed backstop working as intended:
  revoke is courtesy, expiry is law.

## Open variables (no silent TODOs)

- Where does the real OAuth token for `arena-auth` live — runner box env, a Worker secret, a file
  mounted only into the proxy container? (Leaning: mounted only into the proxy container.)
- Is a "quota-only" Claude token even mintable, or is any OAuth token full-scope? If full-scope, the
  proxy's compromise blast-radius is larger — name it.
- Does `publish.yml` run on the privileged runner (has the box) or a GitHub-hosted runner? It needs
  no self-hosted anything — a GitHub-hosted runner with only a PR token is cleaner and further from
  the box's secrets. (Leaning: GitHub-hosted.)
