// arena/budget-proxy — the cage around the monster.
//
// A tiny Cloudflare Worker that lets the arena's agents SPEND, but never more than a hard cap and
// never with the real card number in the repo. It is a capped *authorization* primitive:
//
//   POST /authorize { "amountCents": 500 }   -> approve or refuse against a lifetime cap
//   GET  /status                             -> how much of the cap is spent
//
// SECURITY POSTURE (read before changing anything):
//   * FAIL CLOSED. Spending is irreversible, so every uncertain path REFUSES: a missing/wrong token
//     is 401, a malformed amount is 400, any thrown error is a 500 with approved:false. Uncertainty
//     removes authority; it never grants it.
//   * ATOMIC cap. The counter lives in a single Durable Object instance, whose fetch handler runs
//     single-threaded — so concurrent /authorize calls are serialized and can NEVER both read the
//     same "spent" and both slip under the cap (the eventual-consistency race that makes Workers KV
//     the wrong tool for money).
//   * The cap is a LIFETIME total (cents), not a daily allowance. It does not auto-reset — raising
//     or resetting it is a deliberate admin act (a new deploy or the /admin/reset path below with a
//     separate admin token). "Max loss" means max loss.
//   * The real card (PAN) is NOT here yet and MUST NOT be pasted into code or a var. When the arena
//     has a real purchase, the charge is executed server-side from a Worker *secret*, and the caller
//     only ever sees approve/refuse — the PAN never leaves this Worker, never reaches the repo.

const TOKEN_HEADER = /^Bearer\s+/i;

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// Constant-time string compare — avoids leaking the token via response-timing.
function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const enc = new TextEncoder();
  const ba = enc.encode(a);
  const bb = enc.encode(b);
  if (ba.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < ba.length; i++) diff |= ba[i] ^ bb[i];
  return diff === 0;
}

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);

      // --- auth: every path requires the proxy token, checked in constant time ---
      const provided = (request.headers.get("authorization") || "").replace(TOKEN_HEADER, "");
      const expected = env.BUDGET_PROXY_TOKEN;
      if (!expected || !timingSafeEqual(provided, expected)) {
        return json({ error: "unauthorized" }, 401);
      }

      const cap = parseInt(env.TOTAL_CAP_CENTS ?? "", 10);
      if (!Number.isInteger(cap) || cap <= 0) {
        // Misconfigured cap => refuse everything. Fail closed on our own config too.
        return json({ approved: false, error: "cap not configured" }, 500);
      }

      const stub = env.BUDGET.get(env.BUDGET.idFromName("global"));

      if (request.method === "GET" && url.pathname === "/status") {
        return proxyToDO(stub, { op: "status", cap });
      }

      if (request.method === "POST" && url.pathname === "/authorize") {
        const body = await request.json().catch(() => null);
        const amt = body && Number.isInteger(body.amountCents) ? body.amountCents : null;
        // Bound the single-request amount too: a positive integer, never more than the cap itself.
        if (amt === null || amt <= 0 || amt > cap) {
          return json({ error: "amountCents must be a positive integer <= the cap" }, 400);
        }
        return proxyToDO(stub, { op: "authorize", amountCents: amt, cap });
      }

      // --- admin: reset the spent counter. Gated by a SEPARATE admin token, so the everyday
      // spend token can never zero out the ledger. Resetting/raising the cap is the deliberate act
      // that "raise the cap" refers to — it must be harder than spending, not the same authority.
      if (request.method === "POST" && url.pathname === "/admin/reset") {
        const admin = (request.headers.get("x-admin-token") || "");
        if (!env.ADMIN_TOKEN || !timingSafeEqual(admin, env.ADMIN_TOKEN)) {
          return json({ error: "admin unauthorized" }, 401);
        }
        return proxyToDO(stub, { op: "reset", cap });
      }

      return json({ error: "not found" }, 404);
    } catch {
      // FAIL CLOSED — any unexpected error refuses the spend.
      return json({ approved: false, error: "proxy error" }, 500);
    }
  },
};

async function proxyToDO(stub, payload) {
  const r = await stub.fetch("https://budget.internal/rpc", {
    method: "POST",
    body: JSON.stringify(payload),
  });
  return new Response(await r.text(), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

// The atomic ledger. One global instance; its fetch runs single-threaded, so check-then-add is safe.
export class Budget {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const { op, amountCents = 0, cap } = await request.json();
    const spent = (await this.state.storage.get("spent")) || 0;

    if (op === "status") {
      return json({ spent, cap, remaining: Math.max(0, cap - spent) });
    }

    if (op === "reset") {
      await this.state.storage.put("spent", 0);
      return json({ reset: true, spent: 0, cap, remaining: cap });
    }

    // op === "authorize"
    if (spent + amountCents > cap) {
      return json({ approved: false, reason: "cap exceeded", spent, cap, remaining: Math.max(0, cap - spent) });
    }
    const next = spent + amountCents;
    await this.state.storage.put("spent", next);
    return json({ approved: true, spent: next, cap, remaining: cap - next });
  }
}
