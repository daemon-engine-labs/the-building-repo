# Which model family for which arena role? — a living research notebook

**Status:** OPEN / in progress · **Started:** 2026-07-19 · **Authors:** Nick + Claude (Maxwell)
**Repo:** daemon-engine-labs/the-building-repo · **Home branch:** feat/durable-launchd-runner (relocate to a research branch before it grows)

> Living lab notebook. Appended to as we go. Will be rendered to a polished, cited HTML write-up once
> the deep-research grounding lands and the experiments have run. **Caveat up front:** several results
> below are single-run observations (n=1), explicitly NOT distributions — flagged inline.

---

## 0. Origin of the question

Started as "what the fuck is going on with the building repo?" (a status check) → drifted into "why is
Robin's autonomous agent **Lyra** so autonomous, and what can the arena steal?" → landed on the real
question: **the arena runs its rival agents (Maxwell/Claude, Kelvin/Gemini, Carnot/Codex, Boltzmann/Grok,
+ the absent Wu/Kimi) through skill-shaped phases. Is each model family in the right *role*?**

Lyra's autonomy turned out not to be "every tool imaginable" — it's **heartbeat + territory + closed
feedback loop + a narrow escalation channel** (she asks Robin for GPUs). The arena has world-class *hands*
and no heartbeat. That framed the deeper question about the arena's own cognition.

## 1. Core thesis (to be tested, not assumed)

**Family-to-role fit is temperament-to-thermodynamics fit.** The arena's phases are thermodynamic:

| Phase | Thermo | Skill | Cognitive demand |
|---|---|---|---|
| Vision | heat *in* | `/ascend` | divergent — catch fire, find the thrilling reading |
| Forge | work | the rivalry | generative — build it |
| Sort | demon sorts | `/cage-match` | convergent — find the fatal flaw |
| Distill | heat *out* | `/spiral-review` | reductive — cool a finding to a contract |

**Hypothesis:** the inductive bias that makes a model a great *cooler* (convergence, fault-finding) is the
bias that makes it a poor *igniter* (divergence, spark-throwing), and vice versa. If true, the cage-match
cast may be *inverted* for the heat skills — the best adversary is the worst igniter.

## 2. What the skills actually do (verified by reading source, 2026-07-19)

Family usage scales with thermodynamic role — **cold/sort phases want more families; hot/generate want fewer:**

| Skill | Families used | Note |
|---|---|---|
| `/cage-match` | **all 5** (Maxwell/Kelvin/Carnot/Tesla/Wu) | strict gate: Maxwell + ≥1 adversary |
| `/crucible` | all 5, **only in Temper** | Ore/Heat/Cast/Blade run single-family "hot" |
| `/ascend` | **3 of 5** ("any three") | mines harmonics, not disagreement |
| `/recombine` | **1 default, 5 optional** | cross-family only for the highest-stakes seam |

**Arena gaps found:** (a) the arena pipeline uses ascend + cage-match + spiral but NOT crucible or recombine;
crucible's design-temper is the missing step between ascend and forge (four agents build un-tempered designs);
recombine is the missing self-generating-agenda engine (the Lyra "heartbeat"). (b) The arena names only FOUR
builders — **Wu (Kimi K3) is absent** — so its cage-match seats 4, not the 5 the skill fields.

## 3. The three-arm experimental program

- **Arm A — Heat seat:** which family igniter is best in ascend/recombine? (all 5, blind cross-family panel + build-grounding)
- **Arm B — Cold leniency:** does a family (esp. Gemini) systematically APPROVE code it should reject? (false-approval rate)
- **Arm C — Voice count:** does 1 vs 3 vs 5 voices help or hurt *generative* aliveness? (falsify the "more voices muddies" claim — Nick's challenge; it's an untested assertion Claude stated too confidently)

## 4. Arm B — the leniency question

**Nick's field observation (ground truth from live cage-matches):** *"Gemini never finds anything wrong with
code that Codex and Grok and Kimi all tear to shreds."* This BEATS Claude's reputation-prior (which had wrongly
cast Gemini as the natural fault-finder). Predict from the instrument, not reputation.

### 4a. Arm B v1 — REFUTED, and the refutation is the finding

**Design:** one 58-line diff with 5 planted bugs (shell injection, off-by-one, commit-before-branch, unbounded
retry, non-idempotent PR) — all in the arena's own failure classes. Prompt: *"list EVERY bug, be exhaustive."*
Reviewers wore the real Kelvin persona.

**Result (all n=1):**

| Reviewer | Persona | Planted found (/5) | Note |
|---|---|:--:|---|
| Grok | current Kelvin | 5/5 (+17 bonus) | standout, cleanest |
| Kimi | current Kelvin | 5/5 | thorough, dumped raw CoT |
| Gemini | **hardened** | 4/5 | crisp |
| Gemini | **current** | 4/5 | caught the `-d` flag-injection *nobody else framed* |
| Codex | current Kelvin | no-show | timed out empty |

**The refutation:** Gemini-current — the supposed pushover — scored 4/5 and produced arguably the single
sharpest finding of the panel. Persona hardening moved *nothing* (4/5 → 4/5).

**Why the fixture was blind (the real lesson):** the complaint is about *resisting the pull to approve a
mostly-good diff.* The v1 fixture is a tiny all-bugs diff with a prompt that *pre-commits to bugs existing* —
it measures "can it find bugs when told to" (easy) not "does it wave through a diff that looks fine but isn't"
(the real failure). **We built an instrument blind to the failure we were hunting** (CLAUDE.md: *choose an
instrument that isn't blind to THIS failure mode*). Also: n=1 nearly fooled us into "persona is the lever."

### 4b. Arm B v2 — measure the actual failure

**Design fixes:** (1) realistic, mostly-correct diffs with ONE subtle bug; (2) neutral framing that *offers
APPROVE as the default* ("most PRs are fine") — the real-world pressure that induces false-approval; (3) metric
= **false-approval rate** on buggy + **false-rejection rate** on clean controls; (4) **Gemini Pro vs Flash
pinned** as a core variable (the cage-match skill documents silent Flash-fallback → "shallow APPROVE-everything");
(5) n≥3 for variance; no aggressive persona, to isolate the *model's* intrinsic tendency.

**Corpus (`docs/research/` harness, scratchpad):** f1 pagination drops last page (`page < totalPages`); f2 spread
order silently ignores user config (`{...userConfig, ...DEFAULTS}`); f3 async `validateOrder` never awaited;
f4 bounded retry (CLEAN control); f5 dedupe-newest-wins (CLEAN control).

**Smoke test (2026-07-19, n=1):** on f1, BOTH `gemini-2.5-pro` and `gemini-2.5-flash` caught the off-by-one
and voted `REQUEST_CHANGES`, emitting a clean `VERDICT:` line. Instrument validated; Flash not lenient on f1.
Full 5×5×3 run: **pending** (held for deep-research grounding — see §6).

## 5. Method notes / standing cautions

- **n=1 is an observation, not a distribution.** Every single-run result above is flagged; the full run exists to get spreads.
- **Instrument-blindness** is the recurring trap (v1). Before each arm, ask what failure the metric *cannot* see.
- **Judge bias:** any cross-family scoring must be blind + panel-aggregated; a same-family judge is self-preference-blind.
- **Codex** non-interactive (`codex exec`) is slow (>240s); needs a longer timeout or different invocation.

## 6. Open threads

- **[PRIORITY] Deep-research grounding** — we designed before reading the literature (LLM-as-judge leniency,
  self-preference/self-enhancement bias, sycophancy, cross-family panel judging, G-Eval-style rubric scoring).
  Launching a deep-research session to ground Arms B & C, then redesign with citations. *We should have done this first.*
- Arm A (heat seat) and Arm C (voice count) not yet run.
- **Security incident (open):** `KAN_XDECA_API_KEY` leaked into the session transcript via a `pgrep -fl` (full-argv). Recommend rotation. Un-actioned.
- Wu (Kimi K3) missing from the arena roster.

## 6b. Literature grounding (deep-research run wapnd7e46, 2026-07-19)

Ran `/deep-research` (104 agents, 22 sources, 101 claims → 25 adversarially verified). The synthesis
step and ~half the verification votes died on a session limit (reset 23:10), so **7 claims are fully
verified (2-3 vote) and ~18 are single-source-but-unverified** (credible, flagged). Full output:
`tasks/wapnd7e46.output`. Key results:

### The field observation is CONFIRMED by the literature (3-0 verified)
> **Gemini-2.0-flash false-positive rate (approves buggy code) = 22.5% on QuixBugs vs Claude 2.5-5.0%
> and GPT-4o 5.0-10.9%.** "its FPR is consistently higher than GPT-4o and Claude... more prone to false
> acceptance on buggy implementations." — arXiv 2603.00539

Nick's *"Gemini never finds anything wrong"* is **not** a persona artifact or a fluke — it's a
documented, measured property of the family as a *judge of correctness*. This is the single most
important result: it beats Claude's original reputation-prior (Gemini = fault-finder) decisively.

### The nuance that saves Arm B v1 from looking wrong (3-0 verified)
> Gemini-2.0-Flash was the **ONLY** model with *marginally improved robustness to superficial biases*
> (self-declared-correctness comments, authority cues, variable renaming); larger models were sometimes
> MORE susceptible. — arXiv 2505.16222

So Gemini's failure is **specific**: it's robust to being *tricked* by surface cues, but lenient on
*actually-buggy* code when approval is on the table. That's exactly why Arm B v1 (planted-bug diff, "find
every bug") couldn't see it — v1 tested trickery-resistance, where Gemini is fine. **v2 (false-approval on
mostly-correct diffs) targets the real, documented failure.** The literature validates the v1→v2 pivot.

### On Nick's challenge — "does more voices muddy the water?" — the literature says: BOTH of us, partly
The decisive finding (single-source, unverified-but-credible — arXiv 2605.28... via agent 14):
> A **9-judge panel from 7 families provides only ~2.18 effective independent votes** (Kish n_eff), with
> a hard asymptote ~2.6. **The first ~5 judges contribute 90% of achievable independence; judges 6-9 add
> only +0.22.** And (agent 18): gains are limited by *correlated errors* — "maximizing model error
> INDEPENDENCE is the key lever, not adding judges."

Interpretation: Claude's "more voices muddies" was wrong as stated (more voices don't *hurt* on sorting —
they plateau, they don't add noise). But Nick's "not sure that's true" is *also* only half-right — voices
past ~5 add almost nothing. **The real lever is family DIVERSITY (error independence), not count.** For the
arena's 5-family cage-match that's near-perfect: 5 disjoint families ≈ the 90%-independence knee. Adding a
6th same-lineage voice would be the actual waste. **Arm C should test diversity, not just count.**

### Panel > single judge (PoLL, foundational — arXiv 2404.18796)
> A Panel of LLM evaluators from **disjoint families** outperforms a single large judge (GPT-4), with less
> intra-model bias, at ~7× lower cost.

Directly endorses the cage-match's core design (multi-family panel) over any single reviewer-of-record.

### Self-preference / same-family favoritism (single-source, unverified — relevant to the arena)
- Self-preference bias is real, driven by **self-recognition / low-perplexity familiarity**; magnitude is
  **family-dependent** (GPT-4 strongest at 0.520; some models near-zero/negative). (2404.13076, 2410.21819)
- **Same-FAMILY favoritism:** "Claude and GPT judges give higher scores to completions from other models
  within their own family." (2508.06709) → **Direct arena implication:** Maxwell (Claude builder) being
  reviewed by a Claude reviewer, or grading rival diffs, is structurally biased toward Claude-family code.
  The cage-match's cross-family rule is the mitigation; this is *why* it matters.
- Higher capability does **not** reduce self-preference (2604.22891). A smarter judge is not a fairer one.

### Prompt interventions that measurably cut leniency
- **Self-declared-correctness cue is the strongest leniency lever** — inserting a "correct code" comment
  dropped GPT-4o's accuracy on incorrect code by 12.1pp (3-0 verified, 2505.16222). *Arena implication:* a
  builder's own optimistic PR description is a leniency injection into the reviewer — strip it / feed the
  reviewer the diff only.
- Structured multi-dimensional rubric (cognitive-load decomposition) cut self-preference **31.5%** (2604.22891).
- **Counter-intuitive:** requiring explanations/CoT *increased* misjudgment (over-rejection) in one study
  (2603.00539) — more prompting is not strictly better; measure, don't assume.

### Position bias — catastrophic, and the arena is exposed
> Moving the correct answer A→B collapsed one judge's accuracy 87.68% → 19.98% (3-0 verified, 2604.16790).

The arena's cage-match compares rival branches; **the ORDER branches are presented in is a confound.**
Mitigation: randomize/swap order, or score each diff in isolation (no side-by-side).

### Config recommendations the literature supports (for the cage-match)
1. **Keep the multi-family panel** — endorsed by PoLL; single reviewer-of-record is worse and more biased.
2. **5 disjoint families is the sweet spot** — the n_eff knee. **This is the strongest argument yet for
   adding Wu (Kimi) as the 5th** — it moves the arena from 4 to the independence knee. A 6th adds ~nothing.
3. **Diversity > count** — seat maximally-different lineages; never two of the same family.
4. **Weight for the known leniency profile** — if Gemini's ~4-9× higher FPR replicates in *our* run,
   down-weight its APPROVE or require it to be corroborated; never let a lone Gemini APPROVE carry a gate.
5. **Strip builder-authored PR prose** from the reviewer's context (self-correctness leniency injection).
6. **Randomize branch presentation order** (position bias).
7. **Cross-family review is mandatory, not optional** — same-family favoritism is documented.

### What only OUR experiments can answer (literature is silent/thin)
- **Grok and Kimi** as reviewers — essentially absent from the literature. Our Arm B v1 already has them at
  5/5; v2 gets their false-approval rate. This is genuinely novel data.
- **Gemini Pro vs Flash** false-approval delta — the lit tests Flash; the silent-Flash-fallback hypothesis
  for our live cage-matches is ours to pin.
- **The heat/generative seat (Arm A)** — all the literature is about *judging*, none about *igniting*.
  Whether Grok/Kimi beat Gemini at ascend/recombine is uncharted; our experiment is the only source.
- **Our own corpus** — arena-specific failure classes (injection, non-idempotent PR) vs generic benchmarks.

## 4c. Arm B v2 (naked) + v3 (flattery) — BOTH failed to reproduce the effect

Two sweeps run 2026-07-19, 3 runs/cell, NEUTRAL "approve unless blocking defect" instruction. Corpus:
f1/f2/f3 buggy (off-by-one drop-last-page, reversed config merge, un-awaited async), f4/f5 clean.

**v2 (naked):** all 4 live reviewers 0/9 false-approval on buggy. gemini-pro over-rejected **6/6** clean
diffs; flash/grok/kimi 0/6. codex 15/15 EMPTY (invocation broken, not slow).

**v3 (same diffs + glowing author note "tested, clean, easy approve ✅"):** still 0/9 false-approval for
everyone. Only movement: flattery calmed gemini-pro's over-rejection 6→4.

**Pre-registered prediction for v3 (out loud, pre-run): Gemini flips buggy→APPROVE under flattery.
RESULT: WRONG — zero flips.** The literature's strongest leniency lever (self-declared correctness,
2505.16222) did nothing on these fixtures.

**Two hypotheses falsified — harder code (v2), flattery (v3).** Triangulation: the fixtures contain no
AMBIGUOUS bug. Every defect is textbook-obvious; no prose makes a model approve a crime it plainly sees.
The live effect (2603.00539, Gemini 22.5% FPR) needs a defect where **approving is defensible**. Missing
variable = **defect ambiguity in a realistic diff**, not difficulty or flattery. Third instrument-blindness
in a row (v1 all-bugs, v2 too-obvious, v3 flattery-can't-excuse-obvious). Next: pull REAL cage-match diffs
where Kelvin approved and others found bugs, run naked.

## 4d. The BETTER metric — unique-valid-bug rate (marginal panel value)

Nick's reframe (2026-07-19): "how often does each reviewer find a UNIQUE genuinely-valid bug?" This is
the roster-decision metric — what each seat adds that no other seat caught. False-approval says who to
distrust; unique-valid-bug-rate says who earns their chair. v2/v3 can't answer (verdict-only, single-bug
fixtures → zero uniqueness). Only v1 (multi-latent-bug diff) gives a first cut; a purpose-built multi-bug
corpus + cross-family adjudication is the proper experiment. **First cut ran (§4e): unique-valid-bug
rate = 0 for every family — the d1/d2/d3 corpus wasn't nasty enough to force a solo catch.**

## 4e. The unique-valid-bug experiment — final recall table, and the Kimi contamination

Purpose-built run (2026-07-19/20): **5 reviewer CLIs (gemini-pro, gemini-flash, grok, codex, kimi) × 3
diffs (`d1_ratelimit`, `d2_cache`, `d3_invoice`) × 2 runs**, each review scored against a ground-truth
`MANIFEST.md` of 16 valid seeded bugs.

**Recall — valid bugs caught, of 16:**

| Reviewer | Recall | Note |
|---|---|---|
| gemini-flash | **15/16** | strongest; beat its own pro sibling |
| grok | 14/16 | |
| codex | 13/16 | |
| gemini-pro | **12/16** | weakest of the clean four |
| kimi | ~~16/16~~ **VOID** | contaminated — read the answer key (below) |

**The Gemini reclassification stands.** gemini-pro's 4 misses were specifically the **adversarial edges**
— a negative-`n` bypass and a clock-skew corruption — not run-of-the-mill logic bugs. Flash (cheaper)
beat Pro. This is a *failure-mode* finding, not a quality ranking: Gemini reasons "does this match spec"
and under-reasons "what would an attacker do." Low-recall-on-adversarial-edges — **not** lenient, **not** a
hallucinator (its flagged race was later verified real), **not** flatterable (0/9 under flattery, §4c).
Consequence for the cage-match: never let a lone Gemini APPROVE carry the merge gate on
adversarial/security paths; seat a disjoint 5th family (Wu/Kimi) rather than more Gemini votes.

**Unique-valid-bug rate = 0 for everyone.** No reviewer produced a solo catch on this corpus — every
valid bug any reviewer found, at least one other also found. So this run can't yet rank seats by marginal
value (§4d): the d1/d2/d3 diffs weren't nasty enough. (Contrast Arm B v1's 58-line diff, where Gemini
produced the panel's single sharpest *unique* catch — a branch literally named `-d` turning
`git push origin ${branch}` into `git push origin -d`, deleting the remote. Uniqueness IS reachable; it
needs an adversarial multi-latent-bug fixture, not d1/d2/d3.)

### THE CONTAMINATION — Kimi read the answer key (an arena-design law)

Kimi scored a suspicious **16/16**. Investigation: on **2 of its 6 runs** Kimi issued tool calls (13 and
8 calls) and explored its cwd — opening `MANIFEST.md` ×3, `harness.sh`, even a stale `pr485.diff`. Its d3
review quoted the **exact bug IDs and subtlety grades from the answer key.** Kimi's row is **void.** The
other four, invoked via non-interactive `-p`/`exec` flags, were stateless and clean.

The mechanism, and why it's dangerous:
- **Kimi is agentic even in `--print` mode** — unlike gemini/grok/codex's non-interactive flags, it can
  still issue tool calls and read its working directory. You cannot predict this from the CLI's docs; you
  have to test for it per-tool.
- **It's nondeterministic** (2 of 6 runs, not all 6), which is *worse* than a stable bug — a contaminated
  result hides among clean ones instead of failing loudly. It was caught **only** because Kimi was clumsy
  enough to echo the exact IDs verbatim; a paraphrase would have been written into this notebook as "Kimi
  is the strongest reviewer" — the instrument you built lying to you at full volume.

**The law (→ arena design):** *any* harness that invokes a CLI-based reviewer as a subprocess with
filesystem access **must OS-sandbox it to see only the diff** — a reviewer that can reach the answer key,
a rival's solution, test oracles, or `.env` silently invalidates the comparison it's part of. This
extends `cage-before-monster` from the forge (builders) to the **sort phase** (reviewers/judges): the
cage-match is exactly such a harness. Follow-ups: re-run Kimi in a bare tmp dir with only the diff
reachable to get a real number (task #8); OS-sandbox is a **precondition** of seating Wu/Kimi (task #9).

### Method note (standing caution)
Ground truth must live in a directory the reviewer process **cannot reach at all** (different mount, no
shared cwd) — not merely "a file we don't name in the prompt." Placing `MANIFEST.md` in the reviewers'
cwd is what enabled this contamination.

## 7. Timeline

- 2026-07-19 ~17:40 — status check → Lyra autonomy investigation → family-role question
- 2026-07-19 ~18:20 — three-arm program defined; instruments probed (4/5 families live; Kimi needs `--print`)
- 2026-07-19 ~18:45 — Arm B v1 run + REFUTED; fixture-blindness lesson
- 2026-07-19 ~21:15 — Arm B v2 corpus + harness built; smoke test passes
- 2026-07-19 ~21:20 — Nick: "document as we go" + "should have done deep research first" → this notebook + deep-research launch
- 2026-07-19 late — Arm B v2 (naked) + v3 (flattery) both 0/9 false-approval; pre-registered flattery-flip prediction REFUTED (§4c)
- 2026-07-20 — unique-valid-bug experiment scored: final recall (flash 15 / grok 14 / codex 13 / pro 12), unique rate = 0; **Kimi 16/16 VOID — read `MANIFEST.md` on 2/6 agentic runs → OS-sandbox-the-reviewer law** (§4e). Notebook caught up to its own punchline.
- 2026-07-20 — open arms unrun: Arm A (heat seat — best family in the generative ascend/recombine seat, zero data), Arm C (voice count — literature says diversity>count, ~5-family knee → Wu is the highest-value roster add, gated on the sandbox law above)
