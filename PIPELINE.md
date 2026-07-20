# PIPELINE — the arena is a heat engine

The arena runs one thermodynamic cycle per issue. Each phase is one of Nick's own cognitive
skills, ported from interactive (you-plus-Claude) to autonomous (agents on the runner). The lab
builds the way its author thinks: **generate alive → forge → adversarially sort → distill the lesson.**

```
   heartbeat ─▶ issue  ──▶  ① ASCEND ──▶  ② FORGE ──▶  ③ CAGE-MATCH ──▶  ④ SPIRAL ──▶  merge (you)
   (self-fed)   (wish)      heat in        work          demon sorts        heat out
   /recombine               /ascend        3 rivals       /cage-match        /spiral-review
```

The issue is usually a human's wish — but it need not be. The **heartbeat** (`HEARTBEAT.md`) is the
arena's generative source: a daily pulse that runs `/recombine` over the arena's own capabilities and
files its own issue, so the cycle can turn without being fed. It's caged by default (its issues can't
trigger a build until a bot identity is added to `allowlist.txt`), which is why it's drawn dashed —
present, disarmed, one deliberate merge away from beating.

| # | Phase | Skill | Thermo | What runs |
|---|---|---|---|---|
| 1 | **Vision** | `/ascend` | heat *in* | Heat the raw issue through the five termini (Ember→Kindle→Combust→Resonance→Silence). Select the most *alive* build-vision, not the literal-dead reading. Output: a vision brief the builders work from. |
| 2 | **Forge** | the rivalry | work | Maxwell, Kelvin, Carnot, Boltzmann each build the vision on their own branch. |
| 3 | **Sort** | `/cage-match` | demon sorts | The three cross-review adversarially (each with a different inductive bias). Strict merge gate. Rounds repeat until consensus. Picks the winner and hardens it. |
| 4 | **Distill** | `/spiral-review` | heat *out* | When a round yields 3+ rhyming findings, spiral them into one principle → PR to `agents/*/*.md`. Heat out of this cycle preheats the next. |

## Why the pantheon is the point

Cage-match's four reviewers *are* the four builders — Maxwell (Claude), Kelvin (Gemini), Carnot
(Codex) — the thermodynamicists who taught us how order is wrung from heat. The value of a
cage-match is that the reviewers have **different inductive biases**: same-family review approves
what compiles and misses what the code is *for*. So each reviewer gets a distinct lens
(`agents/<name>/review.md`):

- **Maxwell — the demon at the gate.** Sorts signal from noise. Reviews for *purpose and correctness*: does it do what it's FOR? Trust boundaries, feature-interaction, state-space.
- **Kelvin — absolute zero.** The exacting floor. Reviews for *failure at the limits*: nulls, empty sets, races, the cold edge cases that only bite in production.
- **Carnot — the ideal engine.** Maximum work from the cycle. Reviews for *efficiency and simplicity*: is this the least code? Reuse over reinvention, no wasted motion.
- **Boltzmann — the ensemble.** Statistical mechanics (`S = k log W`). Reviews for *the aggregate and the improbable*: does a per-item property hold across the whole distribution of inputs and states? Emergent, probabilistic, load-dependent failures.

## The two governing decisions

**Spiral → persona PRs are gated by your merge.** When spiral distills a recurring class of mistake
into a principle, it opens a PR editing the relevant persona/review file. That principle only takes
effect when *you* approve the merge (CODEOWNERS enforces this). The forge evolves itself — but the
taste oracle stays human. This is the self-evolution loop from the website, made mechanical.

**Cage-match is unbounded — bounded on *non-progress*, not on round count.** Rounds repeat as long
as each one *reduces* open findings (truly unbounded toward consensus). A convergence detector
(plateau / oscillation / regression — the same trajectory analysis as the `forge` CLI) watches for
a stall: if findings recur without net progress, the loop stops chasing its tail and **escalates to
you** to break the tie. A round cap would kill a review one round from done; a progress detector only
intervenes when the rounds have stopped earning themselves.

## The compounding loop

The distilled principle from phase 4 merges into the builders' personas, so the *next* issue's
agents are sharper. Heat exported from one cycle preheats the next. That is why the forge *spirals*
rather than merely repeats — and why the website's spiral was never just decoration.

## Honest limit

`/ascend`, `/cage-match`, `/spiral-review` are interactive skills built with Nick's judgment in the
loop. Ported to the autonomous runner, their *structure* survives (five termini, cross-review,
finding-distillation are all structured prompt-sequences) but the *taste oracle* does not. The
mitigation is deliberate: you remain the **merge gate** on everything durable — the pipeline
proposes, your approval is the final "audience oh."
