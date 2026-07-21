# arena/spend-requests — the Rail-B (card-present) intake

This directory is the **only** way a build agent can express a card-present purchase. An agent that
wants to buy something writes a single file here, `<requestId>.json`, matching
[`../spend-request.schema.json`](../spend-request.schema.json) and validated fail-closed by
[`../spend-request.mjs`](../spend-request.mjs).

## Why a file, and not an API call

The agent runs with `--dangerously-skip-permissions` on a runner with direct egress. If it held a
card or a spend token, a prompt injection (via issue text) could spend it. So it holds **neither**.
Its maximum power is to *author a wish as data* in its PR branch. That wish then crosses four gates
before any money moves (four distinct *mechanisms* — note that today the same human, Nick, performs
gates 1–3, so they are not four *independent* approvers; they are defence-in-depth against different
failure modes, not four uncorrelated principals):

1. **Code-owner merge** of this file (CODEOWNERS guards `/arena/`) — Nick sees the purchase in the diff.
2. **`spend-approval` GitHub Environment reviewer** — a second, distinct click.
3. **Single-use Telegram HMAC approval token** bound to `(requestId, amountCents, merchant)`.
4. **Issuer 3DS push** to Nick's phone — a per-charge gate no software can remove.

Plus the hard cap: a dedicated bank account funded to ~$20 (max loss = balance) and the budget-proxy's
atomic lifetime counter.

**Scope of P0's enforcement (proven vs. dependent).** In P0 the validator + `spend.yml` are a
*fail-closed data linter* over untrusted request data — proven by tests. Their *trust-boundary teeth*
depend on repo config that is NOT in this diff: because `pull_request` runs the PR's own `spend.yml`,
the only real backstop against a PR that rewrites the gate is **required** CODEOWNERS review on
`/.github/` and `/arena/` (branch protection). Until that is configured, treat P0 as "validated shape
on CI", not "a trust boundary a hostile PR cannot edit". The merchant denylist here is likewise a
*cheap early filter*, NOT the enforcement of "never buy API credits" — it is substring-based and
non-exhaustive; the real, structural rule is the Worker's POSITIVE merchant allowlist, which ships in a
later phase.

The autonomous, real-time "hire a human to solve a CAPTCHA" path is **Rail A** — a pre-funded merchant
balance the Worker draws down via API. Rail A needs no file and no card; its blast radius is the
prepaid balance. Only *arbitrary card-present* purchases use this directory.

## Status

Phase **P0**: the schema, the validator, and the (inert) `spend.yml` gate exist. No executor, no
secrets, no card. A merged request here does nothing yet — the money-moving executor lands in a later,
`/cage-match`-gated phase. See the plan ("the Spend Cage").
