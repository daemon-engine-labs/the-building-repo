# budget-proxy — the cage around spending

The arena's agents can be given the power to **spend money** — but never more than a hard cap, and
never with the real card number anywhere in this repo. This is Phase 5 of the arena's security model
(`SETUP.md`): *"a tiny service you host that holds the real card, enforces a hard daily cap, and only
honours authenticated, rate-limited calls."*

It's a Cloudflare Worker exposing a capped **authorization** primitive:

```
POST /authorize   { "amountCents": 500 }   Bearer <BUDGET_PROXY_TOKEN>   -> approve / refuse
GET  /status                                Bearer <BUDGET_PROXY_TOKEN>   -> spent / cap / remaining
POST /admin/reset                           x-admin-token: <ADMIN_TOKEN>  -> zero the counter (raise/reset)
```

## Why it's shaped this way

- **Fail closed.** Spending is irreversible, so every uncertain path *refuses*: missing/wrong token →
  401, malformed amount or JSON → 400, any thrown error → 500 with `approved:false`. Uncertainty
  removes authority; it never grants it.
- **Atomic cap.** The counter lives in a single Durable Object instance whose handler runs
  single-threaded, so concurrent `/authorize` calls are serialized — they can never both read the
  same `spent` and both slip under the cap. (Verified: 40 concurrent $1 charges against a $20 cap →
  exactly 20 approved, spent lands on exactly 2000, never over. Workers KV would race here; that's why
  it's a DO.)
- **Lifetime cap, not daily.** `TOTAL_CAP_CENTS` is a running total that does **not** auto-reset —
  "max loss" means max loss. Raising or resetting it is a deliberate act via `/admin/reset`, gated by
  a **separate** admin token so the everyday spend token can never zero the ledger.
- **Two tokens, two blast radii.** `BUDGET_PROXY_TOKEN` (spend/read) lives in the arena's `privileged`
  GitHub environment. `ADMIN_TOKEN` (reset/raise) is a Worker-only secret — the arena never needs it.
- **The card is not here.** No PAN in this repo, in a var, or in the token. When the arena has a real
  purchase to make, the charge is executed *server-side from a Worker secret* and the caller only ever
  sees approve/refuse — the number never leaves the Worker.

## Deploy

```sh
cd budget-proxy
export CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=...
wrangler deploy
printf '%s' "$(openssl rand -hex 32)" | wrangler secret put BUDGET_PROXY_TOKEN   # also set in GH privileged env
printf '%s' "$(openssl rand -hex 32)" | wrangler secret put ADMIN_TOKEN
# sync the SAME BUDGET_PROXY_TOKEN into the arena so the privileged path can present it:
#   gh secret set BUDGET_PROXY_TOKEN --env privileged --repo daemon-engine-labs/the-building-repo
```

Set `TOTAL_CAP_CENTS` in `wrangler.toml` (default `2000` = $20.00).

## Test

```sh
BUDGET_PROXY_URL=https://arena-budget-proxy.<subdomain>.workers.dev \
BUDGET_PROXY_TOKEN=... ADMIN_TOKEN=... ./test.sh
```

## Arming real spend (NOT done here — the next gate)

This MVP is the capped **authorization** primitive, deployed and proven at **$0 risk with no card**.
Turning it into real spending is a deliberate, cage-matched step:

1. **Card side (your hands):** set the bank/card limit to match the cap, so `$20` is enforced at the
   *issuer*, not only by this code. With a real PAN in the proxy, the proxy counter alone is soft.
   Prefer swapping in a **virtual card** at this point.
2. **Execution:** add per-merchant server-side charge logic that reads the card from a Worker secret
   and calls `/authorize` first, refusing on `approved:false`.
3. **Arena side:** flip `spend` from `deny` in the relevant `agents/*/tools.json` — and only for the
   allowlisted privileged path. **Spend must stay unreachable from any untrusted-input path** (the
   heartbeat pulse reads attacker-controllable public issue text — see `HEARTBEAT.md`). Arming spend
   is a trust-boundary change: it goes through `/cage-match`.
