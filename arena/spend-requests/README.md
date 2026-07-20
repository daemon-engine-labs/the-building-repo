# arena/spend-requests — the Rail-B (card-present) intake

This directory is the **only** way a build agent can express a card-present purchase. An agent that
wants to buy something writes a single file here, `<requestId>.json`, matching
[`../spend-request.schema.json`](../spend-request.schema.json) and validated fail-closed by
[`../spend-request.mjs`](../spend-request.mjs).

## Why a file, and not an API call

The agent runs with `--dangerously-skip-permissions` on a runner with direct egress. If it held a
card or a spend token, a prompt injection (via issue text) could spend it. So it holds **neither**.
Its maximum power is to *author a wish as data* in its PR branch. That wish then crosses four
independent gates before any money moves:

1. **Code-owner merge** of this file (CODEOWNERS guards `/arena/`) — Nick sees the purchase in the diff.
2. **`spend-approval` GitHub Environment reviewer** — a second, distinct human click.
3. **Single-use Telegram HMAC approval token** bound to `(requestId, amountCents, merchant)`.
4. **Issuer 3DS push** to Nick's phone — a per-charge gate no software can remove.

Plus the hard cap: a dedicated bank account funded to ~$20 (max loss = balance) and the budget-proxy's
atomic lifetime counter.

The autonomous, real-time "hire a human to solve a CAPTCHA" path is **Rail A** — a pre-funded merchant
balance the Worker draws down via API. Rail A needs no file and no card; its blast radius is the
prepaid balance. Only *arbitrary card-present* purchases use this directory.

## Status

Phase **P0**: the schema, the validator, and the (inert) `spend.yml` gate exist. No executor, no
secrets, no card. A merged request here does nothing yet — the money-moving executor lands in a later,
`/cage-match`-gated phase. See the plan ("the Spend Cage").
