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

## 7. Timeline

- 2026-07-19 ~17:40 — status check → Lyra autonomy investigation → family-role question
- 2026-07-19 ~18:20 — three-arm program defined; instruments probed (4/5 families live; Kimi needs `--print`)
- 2026-07-19 ~18:45 — Arm B v1 run + REFUTED; fixture-blindness lesson
- 2026-07-19 ~21:15 — Arm B v2 corpus + harness built; smoke test passes
- 2026-07-19 ~21:20 — Nick: "document as we go" + "should have done deep research first" → this notebook + deep-research launch
