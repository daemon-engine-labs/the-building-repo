# SETUP — arming the arena, safely and in order

This is the deliberate, ordered procedure for turning the inert skeleton into a live system.
**The order is the security.** Each phase ends with a check; do not start the next phase until
the current one's check is green. Cage, then monster.

> **Why your Mac needs a Linux VM here.** Self-hosted runners on macOS run as a normal user with
> no cgroups/systemd confinement and no easy per-process egress firewall. A prompt-injected agent
> on attacker-influenced input is exactly the case that demands OS isolation. So the **sandbox
> runner runs inside an ephemeral Linux container** (via `colima` on your Mac) behind an
> **egress-allowlist proxy**. That gives a real wall: fresh environment per job, and the job can
> only reach the handful of hosts we permit.

---

## Phase ordering (the whole map)

| # | Phase | Adds | Risk if skipped/reordered |
|---|---|---|---|
| 0 | Lock down repo Actions settings | (settings only) | A fork PR runs on your runner before any gate |
| 1 | Sandbox runner (Linux, ephemeral, egress-filtered) | the untrusted compute | — |
| 2 | **Prove isolation** | (a test issue) | You trust a wall you never tested |
| 3 | Privileged runner (separate) | the trusted compute | Secrets share a box with untrusted jobs |
| 4 | Wire secrets (environment-scoped) — **LAST** | real OAuth tokens | A token exists before the wall is proven |
| 5 | Budget proxy | spending, capped | The real card is reachable from code |

---

<details open>
<summary><b>Phase 0 — Lock down repo Actions settings (do this first, before any runner)</b></summary>

A self-hosted runner on a **public** repo will, by default, execute fork-PR code on your box.
Close that door before the runner exists.

In **Settings → Actions → General** (`https://github.com/daemon-engine-labs/the-building-repo/settings/actions`):

1. **Fork pull request workflows from outside collaborators** → **"Require approval for all external contributors"** (strictest). This means no fork-PR workflow runs until you click approve.
2. **Workflow permissions** → **"Read repository contents permission"** (default-deny token).
3. Leave Actions **enabled** but note we only ever trigger from `on: issues` (runs from `main`) and, later, `on: pull_request` (no secrets) — never `pull_request_target`.

Then protect the self-modification door so agents can't rewrite their own cage unilaterally:

```bash
# Require review on main, and make .github/** + allowlist.txt owned by you.
printf '/.github/    @nickmeinhold\n/allowlist.txt    @nickmeinhold\n/arena/    @nickmeinhold\n' > .github/CODEOWNERS
# (commit + push), then in Settings → Branches add a protection rule for `main`:
#   - Require a pull request before merging
#   - Require review from Code Owners
#   - Do not allow bypassing the above
```

**Check:** open a PR from a throwaway fork that edits `.github/workflows/triage.yml`. It must (a) require your approval to run, and (b) be blocked from merging without your code-owner review.

</details>

<details>
<summary><b>Phase 1 — Sandbox runner: ephemeral Linux container + egress allowlist</b></summary>

### 1a. A Linux VM on your Mac

```bash
brew install colima docker
colima start --cpu 4 --memory 8 --disk 40   # a Linux VM with a Docker runtime
docker context use colima
```

### 1b. An egress-allowlist proxy (the wall)

Everything the runner does goes through a proxy that only permits known hosts. Create
`runner/egress-allowlist.txt` (domains the agents legitimately need):

```
# GitHub (git + Actions backend — required or the runner can't function)
github.com
api.github.com
codeload.github.com
.actions.githubusercontent.com
objects.githubusercontent.com
pkg-containers.githubusercontent.com
# Model APIs
api.anthropic.com
api.openai.com
generativelanguage.googleapis.com
# Package registries the build may need (tighten later)
registry.npmjs.org
pypi.org
files.pythonhosted.org
```

Run `tinyproxy` (or `squid`) with that allowlist as a sidecar. Minimal `tinyproxy.conf`:

```
Port 8888
Allow 0.0.0.0/0
# Filter file holds the allowlist as regexes; default deny.
Filter "/etc/tinyproxy/allowlist.txt"
FilterDefaultDeny Yes
FilterExtended On
```

```bash
docker network create --internal arena-internal     # no direct route to the internet
docker network create arena-egress                  # proxy sits here, has internet
docker run -d --name egress --network arena-egress \
  -v "$PWD/runner/tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro" \
  -v "$PWD/runner/egress-allowlist.txt:/etc/tinyproxy/allowlist.txt:ro" \
  vimagick/tinyproxy
docker network connect arena-internal egress         # proxy bridges both networks
```

The runner container attaches to **`arena-internal` only** (no default route) and is forced
through the proxy via `HTTP(S)_PROXY`. Direct egress is impossible; only allowlisted hosts resolve.

### 1c. The ephemeral runner

Get a registration token (one per registration; ephemeral runners consume one job then exit):

```bash
gh api -X POST repos/daemon-engine-labs/the-building-repo/actions/runners/registration-token -q .token
```

`runner/Dockerfile` (pin the latest runner version):

```dockerfile
FROM ghcr.io/actions/actions-runner:latest
# image already runs as the unprivileged `runner` user
```

Run it ephemeral, sandbox-labelled, behind the proxy, with NO host mounts and NO secrets:

```bash
docker run --rm --network arena-internal \
  -e HTTP_PROXY=http://egress:8888 -e HTTPS_PROXY=http://egress:8888 \
  -e NO_PROXY=localhost,127.0.0.1 \
  ghcr.io/actions/actions-runner:latest \
  bash -c "./config.sh --url https://github.com/daemon-engine-labs/the-building-repo \
            --token <REG_TOKEN> --labels self-hosted,sandbox --ephemeral --unattended \
            --name sandbox-\$(hostname) && ./run.sh"
```

Wrap that in a `while true; do …; done` loop (or a launchd job) so a fresh ephemeral runner
re-registers after each job. **Each job thus gets a clean container.**

**Check:** `gh api repos/daemon-engine-labs/the-building-repo/actions/runners -q '.runners[].labels[].name'`
shows `self-hosted` + `sandbox`, status `online`.

> **Named tradeoff (the shortcut, if you ever take it):** running the runner natively on macOS
> under a dedicated user with no secrets skips the VM/proxy. It still can't leak a secret (there
> are none on this path), but a compromised job gets unfiltered network and your real OS. Acceptable
> ONLY for the zero-secret propose path, never for privileged. Recommendation: don't — the proxy is
> an hour of setup that turns "could abuse my machine" into "could waste some CPU."

</details>

<details>
<summary><b>Phase 2 — PROVE isolation (the gate that unlocks everything else)</b></summary>

With the sandbox runner online and **no secrets yet added**, open a test issue **from a GitHub
account that is NOT in `allowlist.txt`** (a throwaway, or ask a friend). The `triage` workflow
should:

1. `gate` → resolve `trusted=false`.
2. `build-sandbox` → run the **"prove isolation"** step, print `secrets visible to this job: {}`
   (only `github_token` at most), and **pass**.

Then, as a deliberate red-team, temporarily add a dummy repo secret named `ANTHROPIC_OAUTH=fake`
and re-run. The proof step's `grep -qiE 'OAUTH|ANTHROPIC|…'` must now **fail the job** — proving
the tripwire works — *then delete the dummy secret*.

**Check:** untrusted issue → sandbox path runs, secrets empty, job green. Dummy secret → job RED.
Only when both are true do you proceed.

</details>

<details>
<summary><b>Phase 3 — Privileged runner (separate box/VM, label <code>privileged</code>)</b></summary>

A **second** runner, isolated from the sandbox one (separate colima VM or separate user), labelled
`self-hosted,privileged`. It only ever runs code authored by allowlisted actors or already merged
to `main`, so its threat model is lower — but keep it separate anyway (defence in depth). Same
ephemeral pattern; it may have broader egress (it builds/publishes real products).

**Check:** runner list shows a second runner with `privileged`; the sandbox runner does **not**
carry that label.

</details>

<details>
<summary><b>Phase 4 — Wire secrets (LAST, environment-scoped)</b></summary>

Create a GitHub **Environment** named `privileged`
(`https://github.com/daemon-engine-labs/the-building-repo/settings/environments`):

- **Required reviewers:** you. (So even an allowlisted trigger pauses for your click before secrets unlock — belt and braces with the allowlist.)
- Add secrets **to the environment**, not the repo, so only `build-privileged` (which declares
  `environment: privileged`) can read them:

```bash
gh secret set ANTHROPIC_OAUTH --env privileged --repo daemon-engine-labs/the-building-repo
gh secret set OPENAI_API_KEY  --env privileged --repo daemon-engine-labs/the-building-repo
gh secret set GEMINI_API_KEY  --env privileged --repo daemon-engine-labs/the-building-repo
```

> **NO spend token, NO card here — reversed from an earlier draft.** An earlier version of this phase
> put `BUDGET_PROXY_TOKEN` in the `privileged` environment. That was the vulnerability: the privileged
> build agent runs with `--dangerously-skip-permissions` on a runner with direct egress, and folds
> attacker-influenceable issue text into its prompt — so *any* spendable credential in its env is a
> credential a prompt injection can wield (and `deny:["spend"]` in `tools.json` enforces nothing —
> nothing reads it). The spend token therefore lives ONLY in the separate **`spend-approval`**
> environment used by `spend.yml`, never here. See Phase 5 and `arena/spend-requests/README.md`.
>
> Even so, this set is contained: an OAuth/provider token, if leaked, burns compute you can rotate —
> it moves no money.

**Check:** re-run the dummy-secret test from Phase 2 against the **sandbox** path — the env secrets
must remain invisible there (they're scoped to the `privileged` environment). Sandbox stays empty.

</details>

<details>
<summary><b>Phase 5 — The Spend Cage (so a card is never in the repo, nor reachable by an injected agent)</b></summary>

The budget-proxy Worker (deployed) is a pure **authorizer**: `POST /authorize {amountCents}` →
approve/refuse against an atomic $20 lifetime cap. It holds no card and moves no money. Arming real
spend is a deliberate, phased, `/cage-match`-gated build — the **Spend Cage** — whose one rule is:
*the spendable credential never lives in the general build agent's hands.* Spend is mediated so the
agent can only **request** a purchase (as data), never wield a card:

- **Rail A (autonomous, no card):** pre-funded merchant balances (e.g. 2captcha) the Worker draws down
  via API. Blast radius = the prepaid balance ≤ cap. This is the "hire a human to solve a CAPTCHA" path.
- **Rail B (card-present, buy anything):** the agent writes `arena/spend-requests/<id>.json` (pure
  data). It faces four gates before money moves — code-owner merge, the `spend-approval` environment
  reviewer, a single-use Telegram HMAC approval token bound to `(requestId, amount, merchant)`, and the
  issuer 3DS push to your phone. A separate card-executor (outside the runner) holds the PAN and
  redeems a one-use capability token; the Worker never holds the card, the agent never sees it.
- **Hard cap:** a *dedicated* bank account funded to ~$20 (max loss = balance, issuer-enforced),
  layered with the proxy's atomic counter.
- **"Never buy API credits"** is a merchant denylist enforced at the Worker AND at request-validation.

**Check:** a merged spend-request does nothing until the executor phase is live; an injected agent can
at most *propose* a ≤$20 purchase you consciously approve four times; the repo contains no card data.
Tracked phase-by-phase in the plan (the Spend Cage); live card lands last.

</details>

---

## What I (Claude) can do vs. what needs your hands

- **Your hands:** running `colima`/`docker`, registering runners (needs a token on your box),
  installing on your machine, and clicking the GitHub Settings toggles in Phase 0/4.
- **I can do:** write the `runner/` files (Dockerfile, tinyproxy.conf, the loop script, the egress
  allowlist), wire the `triage.yml` TODOs into real arena steps, build the budget proxy, and open
  the test issue once a runner is online.

Tell me when the sandbox runner is up and I'll drive Phase 2 (the isolation proof) with you.
