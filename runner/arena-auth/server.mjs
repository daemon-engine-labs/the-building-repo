#!/usr/bin/env node
// arena-auth — the sandbox's spend trust boundary.
//
// WHY THIS EXISTS (see docs/crucible/build-sandbox/DESIGN.md, finding T1):
// An untrusted build needs an LLM, an LLM needs a credential, but the sandbox is the place a
// credential must NOT exist — a prompt-injected agent could write it into the diff → artifact → PR
// (a network-independent exfil the egress wall can't see). So the real Anthropic token NEVER touches
// the sandbox. The sandbox holds only a per-job NONCE, which it sends as its Authorization. This
// proxy validates the nonce, strips it, injects the real token, and forwards ONLY the intended
// Anthropic inference surface (method + path allowlist). The token is unexfiltratable because it is
// never on the runner.
//
// The nonce is not a static "dummy": it is single-use-per-job, BUDGET-CAPPED, and REVOKABLE. A
// leaked nonce burns at most ONE job's capped budget and can be killed — not a reusable year-lived
// token. That bounded residual is the accepted tradeoff.
//
// TRUST-BOUNDARY DISCIPLINE (folded from the PR #17 cage-match — Maxwell/Carnot/Tesla):
//   - method+path ALLOWLIST (default-deny), not host-pin alone: a nonce spends on inference, it does
//     not get to enumerate the account's whole API surface.
//   - request headers REBUILT from an allowlist, not denylist-scrubbed: no hop-by-hop/smuggling ride.
//   - responses STREAMED through (not buffered) with usage metered incrementally from the SSE deltas,
//     so the token cap is real for the streaming traffic this proxy actually serves.
//   - pessimistic token RESERVATION on admission, so concurrent requests on one nonce can't all pass
//     the budget check before any records usage.
//   - request-body SIZE cap + upstream TIMEOUT: an injected agent can't OOM/hang the concentrator.
//
// TWO listeners, deliberately separate:
//   - DATA  (DATA_PORT, 0.0.0.0): what the sandbox reaches over arena-internal. Proxies to Anthropic.
//   - ADMIN (ADMIN_PORT, 127.0.0.1): mint/revoke nonces + kill switch. Container-loopback ONLY —
//     within a docker network there is no port isolation, so admin must not be on a network the
//     sandbox can route to. Mint via `docker exec arena-auth node server.mjs mint` (host docker
//     access ⇒ privileged).
//
// Dependency-free (node built-ins only), matching arena/*.mjs.

import http from "node:http";
import https from "node:https";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { pathToFileURL } from "node:url";

// ── config ────────────────────────────────────────────────────────────────────
const REAL_TOKEN = process.env.REAL_OAUTH_TOKEN || "";
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || "";
const DATA_PORT = parseInt(process.env.DATA_PORT || "8080", 10);
const ADMIN_PORT = parseInt(process.env.ADMIN_PORT || "8081", 10);
const DATA_BIND = process.env.DATA_BIND || "0.0.0.0";
// ADMIN binds container-LOOPBACK by default (see header). A non-loopback bind is a break-glass that
// must be OPTED INTO explicitly — start() refuses otherwise (fail-closed > a comment).
const ADMIN_BIND = process.env.ADMIN_BIND || "127.0.0.1";
const ADMIN_ON_NETWORK_ACK = process.env.I_UNDERSTAND_ADMIN_ON_INTERNAL === "1";
const UPSTREAM_HOST = "api.anthropic.com";
const OAUTH_BETA = "oauth-2025-04-20";

// Budget caps. maxRequests is the HARD spend fuse; maxTokens is a real meter via SSE usage parsing,
// bounded under concurrency by the per-request reservation below.
const DEFAULT_MAX_REQUESTS = parseInt(process.env.DEFAULT_MAX_REQUESTS || "40", 10);
const DEFAULT_MAX_TOKENS = parseInt(process.env.DEFAULT_MAX_TOKENS || "300000", 10);
// Server-side CEILINGS an admin mint cannot exceed (Tesla: clamp attacker-shaped budgets).
const CEIL_MAX_REQUESTS = parseInt(process.env.CEIL_MAX_REQUESTS || "200", 10);
const CEIL_MAX_TOKENS = parseInt(process.env.CEIL_MAX_TOKENS || "2000000", 10);
// Pessimistic per-request token reservation held from admission until the response's real usage is
// known. Bounds concurrent overshoot on a single nonce to reservation accuracy.
const RESERVE_TOKENS = parseInt(process.env.RESERVE_TOKENS || "16000", 10);
// Server-enforced MAXIMUM nonce lifetime (fail-closed by construction). Client-side revoke is a
// best-effort courtesy — a host killed mid-job (SIGTERM) or a wedged `docker exec revoke` can leave a
// spendable nonce alive. The TTL is the LAW that bounds that leak regardless of whether revoke ran
// (cage-match round 2 — Tesla: "revoke is a courtesy; expiry is law"). One hour covers any single
// build with margin; a leaked nonce dies on its own well before it could matter.
const NONCE_TTL_MS = parseInt(process.env.NONCE_TTL_MS || "3600000", 10);
// Hard limits so a hostile sandbox can't OOM/hang the concentrator.
const MAX_BODY_BYTES = parseInt(process.env.MAX_BODY_BYTES || "1048576", 10); // 1 MiB
const UPSTREAM_TIMEOUT_MS = parseInt(process.env.UPSTREAM_TIMEOUT_MS || "120000", 10);

// method+path allowlist (default-deny). Values are exact method + path-prefix pairs on the Anthropic
// inference surface the agent CLI actually needs — NOT the whole origin.
const ALLOWED_ROUTES = [
  { method: "POST", prefix: "/v1/messages" },        // + /v1/messages/count_tokens (prefix covers it)
  { method: "GET", prefix: "/v1/models" },
];
function routeAllowed(method, url) {
  const path = (url || "").split("?")[0];
  // Boundary-anchored: the prefix must be the whole path or a subpath (next char is "/") — NOT a
  // bare startsWith, which would admit /v1/messagesX (cage-match R1: the allowlist must be true
  // regardless of upstream's route table).
  return ALLOWED_ROUTES.some((r) => r.method === method && (path === r.prefix || path.startsWith(r.prefix + "/")));
}

// Outbound REQUEST headers are rebuilt from this allowlist (Tesla/Carnot: rebuild, don't scrub). The
// real Authorization + anthropic-beta are injected separately below.
const REQ_HEADER_ALLOW = new Set(["content-type", "accept", "anthropic-version", "anthropic-beta"]);
// Response headers passed back to the sandbox — everything else (set-cookie, hop-by-hop, upstream
// internals) is dropped.
// request-id intentionally NOT forwarded (cage-match: it's an upstream account-correlatable handle
// that could land in an artifact). content-type is all the CLI needs.
const RES_HEADER_ALLOW = new Set(["content-type", "anthropic-version"]);

// ── nonce registry (in-memory; a proxy restart revokes every live nonce — fail-closed) ──────────
// nonce -> { requests, maxRequests, tokens, reserved, maxTokens, revoked }
const nonces = new Map();
let killed = false; // global kill switch
// In-flight upstream requests so the kill switch / revoke can actually ABORT, not just gate future
// admissions (cage-match: "a kill switch that only stops new work is a future-admission gate, not a
// kill"). Map of upstream req → nonce, so revoke can target one nonce and kill can drop all.
const inFlight = new Map();
function abortInFlight(pred) {
  for (const [up, nonce] of inFlight) {
    if (pred(nonce)) { try { up.destroy(new Error("aborted by admin")); } catch { /* already gone */ } }
  }
}

function clamp(n, def, ceil) {
  const v = Number.isFinite(n) ? Math.floor(n) : def;
  return Math.max(1, Math.min(v, ceil));
}
function mintNonce({ maxRequests, maxTokens } = {}) {
  const nonce = randomBytes(24).toString("base64url");
  nonces.set(nonce, {
    requests: 0,
    maxRequests: clamp(maxRequests ?? DEFAULT_MAX_REQUESTS, DEFAULT_MAX_REQUESTS, CEIL_MAX_REQUESTS),
    tokens: 0,
    reserved: 0,
    maxTokens: clamp(maxTokens ?? DEFAULT_MAX_TOKENS, DEFAULT_MAX_TOKENS, CEIL_MAX_TOKENS),
    revoked: false,
    expiresAt: Date.now() + NONCE_TTL_MS, // server-enforced max lifetime — the fail-closed backstop to client revoke
  });
  return nonce;
}

function safeEqual(a, b) {
  const ab = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

// Admission decision. Counts reserved tokens so concurrent requests on one nonce can't all slip
// under the cap before any records usage.
function checkNonce(nonce) {
  if (killed) return { ok: false, reason: "kill switch engaged", code: 401 };
  if (!nonce) return { ok: false, reason: "no nonce", code: 401 };
  const entry = nonces.get(nonce);
  if (!entry) return { ok: false, reason: "unknown nonce", code: 401 };
  if (entry.revoked) return { ok: false, reason: "revoked nonce", code: 401 };
  if (Date.now() > entry.expiresAt) return { ok: false, reason: "expired nonce", code: 401 };
  if (entry.requests >= entry.maxRequests) return { ok: false, reason: "request budget exhausted", code: 429 };
  if (entry.tokens + entry.reserved + RESERVE_TOKENS > entry.maxTokens) return { ok: false, reason: "token budget exhausted", code: 429 };
  return { ok: true, entry };
}

// Parse Anthropic usage out of a streamed SSE chunk OR a whole JSON body. Returns {input, output} best
// known so far (output is cumulative in message_delta). Robust to partial lines.
function scanUsage(text, acc) {
  // Non-streaming JSON body.
  try {
    const j = JSON.parse(text);
    if (j.usage) {
      acc.input = j.usage.input_tokens || acc.input;
      acc.output = j.usage.output_tokens || acc.output;
      return acc;
    }
  } catch { /* not a whole JSON body — treat as SSE below */ }
  // Streaming SSE: data: {json} lines. message_start carries input; message_delta carries cumulative output.
  for (const line of text.split("\n")) {
    const m = /^data:\s*(\{.*\})\s*$/.exec(line.trim());
    if (!m) continue;
    try {
      const ev = JSON.parse(m[1]);
      const u = ev.usage || (ev.message && ev.message.usage);
      if (u) {
        if (u.input_tokens) acc.input = u.input_tokens;
        if (u.output_tokens) acc.output = u.output_tokens; // cumulative
      }
    } catch { /* partial line across chunk boundary — next chunk completes it */ }
  }
  return acc;
}

function bearerFrom(req) {
  const h = req.headers["authorization"] || "";
  const m = /^Bearer\s+(.+)$/i.exec(h);
  return m ? m[1] : null;
}

function denyJson(res, code, reason, req) {
  // Drain any request body FIRST so a keep-alive socket isn't reset mid-response (an early denial
  // that answers before the request finished arriving races the client's body read → ECONNRESET).
  if (req) { req.on("error", () => {}); req.resume(); }
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify({ error: { type: "arena_auth_denied", message: reason } }));
}

// ── DATA plane ──────────────────────────────────────────────────────────────────
const dataServer = http.createServer((req, res) => {
  // 1) method+path allowlist FIRST — a nonce spends on inference, it does not enumerate the account.
  if (!routeAllowed(req.method, req.url)) {
    denyJson(res, 403, `route not allowed: ${req.method} ${(req.url || "").split("?")[0]}`, req);
    return;
  }
  // 2) nonce admission (counts reservation).
  const nonce = bearerFrom(req);
  const verdict = checkNonce(nonce);
  if (!verdict.ok) { denyJson(res, verdict.code, verdict.reason, req); return; }
  const entry = verdict.entry;
  entry.requests += 1;             // hard fuse: counted on admission (a hung client still burns a slot)
  entry.reserved += RESERVE_TOKENS; // pessimistic hold until real usage lands
  let settled = false;
  const settle = (used) => {
    if (settled) return; settled = true;
    entry.reserved = Math.max(0, entry.reserved - RESERVE_TOKENS);
    entry.tokens += Math.max(0, used);
  };

  // 3) read the request body with a hard size cap.
  const chunks = [];
  let size = 0;
  let aborted = false;
  req.on("data", (c) => {
    if (aborted) return;
    size += c.length;
    if (size > MAX_BODY_BYTES) {
      aborted = true;
      settle(0);
      // Deliver 413 in full, THEN cut the socket (so we don't keep eating the oversized body) —
      // destroying req mid-stream would RST before the 413 reliably reaches the client.
      res.on("finish", () => req.socket && req.socket.destroy());
      res.writeHead(413, { "content-type": "application/json", connection: "close" });
      res.end(JSON.stringify({ error: { type: "arena_auth_denied", message: `request body exceeds ${MAX_BODY_BYTES} bytes` } }));
      return;
    }
    chunks.push(c);
  });
  req.on("end", () => {
    if (aborted) return;
    const body = Buffer.concat(chunks);

    // 4) rebuild outbound headers from an allowlist; inject the real token.
    const headers = {};
    for (const [k, v] of Object.entries(req.headers)) {
      if (REQ_HEADER_ALLOW.has(k.toLowerCase())) headers[k] = v;
    }
    headers["host"] = UPSTREAM_HOST;
    headers["authorization"] = `Bearer ${REAL_TOKEN}`;
    headers["anthropic-beta"] = headers["anthropic-beta"] ? `${headers["anthropic-beta"]},${OAUTH_BETA}` : OAUTH_BETA;
    headers["content-length"] = Buffer.byteLength(body); // trust OUR length, not the client's

    const up = https.request(
      { hostname: UPSTREAM_HOST, port: 443, path: req.url, method: req.method, headers, timeout: UPSTREAM_TIMEOUT_MS },
      (upRes) => {
        // 5) stream through, metering usage incrementally; response headers from an allowlist.
        const safe = {};
        for (const [k, v] of Object.entries(upRes.headers)) {
          if (RES_HEADER_ALLOW.has(k.toLowerCase())) safe[k] = v;
        }
        res.writeHead(upRes.statusCode, safe);
        // Per-response line buffer: an SSE `data:` record can split across TCP chunks, so parse only
        // COMPLETE lines and carry the partial tail forward (cage-match: a chunk-split undercounts
        // usage → overspend). Pass through bytes verbatim; meter from the reassembled lines.
        const acc = { input: 0, output: 0 };
        let lineBuf = "";
        upRes.on("data", (c) => {
          res.write(c);
          lineBuf += c.toString("utf8");
          const nl = lineBuf.lastIndexOf("\n");
          if (nl >= 0) { scanUsage(lineBuf.slice(0, nl), acc); lineBuf = lineBuf.slice(nl + 1); }
        });
        upRes.on("end", () => { if (lineBuf) scanUsage(lineBuf, acc); settle(acc.input + acc.output); res.end(); });
      }
    );
    inFlight.set(up, nonce);
    const done = () => inFlight.delete(up);
    up.on("close", done);
    up.on("timeout", () => { up.destroy(new Error("upstream timeout")); });
    up.on("error", (e) => {
      settle(0); done();
      if (!res.headersSent) { res.writeHead(502, { "content-type": "application/json" }); res.end(JSON.stringify({ error: { type: "arena_auth_upstream", message: e.message } })); }
      else res.end();
    });
    // Client (sandbox) gave up → stop spending on its behalf: abort the upstream request.
    res.on("close", () => { if (!settled) { up.destroy(new Error("client aborted")); } });
    up.end(body);
  });
  req.on("error", () => settle(0));
});

// ── ADMIN plane ─────────────────────────────────────────────────────────────────
const adminServer = http.createServer((req, res) => {
  const auth = bearerFrom(req);
  if (!ADMIN_TOKEN || !safeEqual(auth, ADMIN_TOKEN)) {
    res.writeHead(401, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "admin auth required" }));
    return;
  }
  const chunks = [];
  let size = 0, tooBig = false;
  req.on("data", (c) => { size += c.length; if (size > MAX_BODY_BYTES) tooBig = true; else chunks.push(c); });
  req.on("end", () => {
    if (tooBig) { res.writeHead(413, { "content-type": "application/json" }); res.end(JSON.stringify({ error: "admin body too large" })); return; }
    let payload, bad = false;
    try { payload = chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {}; } catch { bad = true; }
    if (bad) { res.writeHead(400, { "content-type": "application/json" }); res.end(JSON.stringify({ error: "malformed admin JSON" })); return; }
    if (req.method === "POST" && req.url === "/admin/nonce") {
      const nonce = mintNonce(payload);
      const e = nonces.get(nonce);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ nonce, maxRequests: e.maxRequests, maxTokens: e.maxTokens }));
      return;
    }
    if (req.method === "POST" && req.url === "/admin/revoke") {
      const entry = nonces.get(payload.nonce);
      if (entry) entry.revoked = true;
      abortInFlight((n) => n === payload.nonce); // actually cut in-flight spend for this nonce
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ revoked: Boolean(entry) }));
      return;
    }
    if (req.method === "POST" && req.url === "/admin/kill") {
      killed = payload.engaged !== false;
      if (killed) abortInFlight(() => true); // a kill aborts every in-flight request, not just future ones
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ killed }));
      return;
    }
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "unknown admin route" }));
  });
});

// ── startup: fail closed on missing secrets AND on an unacknowledged non-loopback admin bind ──────
export function start() {
  if (!REAL_TOKEN) { console.error("[arena-auth] REAL_OAUTH_TOKEN not set — refusing to start."); process.exit(2); }
  if (!ADMIN_TOKEN) { console.error("[arena-auth] ADMIN_TOKEN not set — refusing to start (admin plane would be open)."); process.exit(2); }
  if (ADMIN_BIND !== "127.0.0.1" && ADMIN_BIND !== "::1" && !ADMIN_ON_NETWORK_ACK) {
    console.error(`[arena-auth] ADMIN_BIND=${ADMIN_BIND} is non-loopback — within a docker network the sandbox could route to admin. Refusing to start. Set I_UNDERSTAND_ADMIN_ON_INTERNAL=1 to break glass.`);
    process.exit(2);
  }
  dataServer.listen(DATA_PORT, DATA_BIND, () => console.error(`[arena-auth] data plane on ${DATA_BIND}:${DATA_PORT} → ${UPSTREAM_HOST} (allowlisted routes only)`));
  adminServer.listen(ADMIN_PORT, ADMIN_BIND, () => console.error(`[arena-auth] admin plane on ${ADMIN_BIND}:${ADMIN_PORT} (ADMIN_TOKEN-gated, loopback-only by default)`));
}

// ── local admin CLI (scriptable minting via `docker exec arena-auth node server.mjs mint`) ────────
// Hits the loopback admin plane so orchestration never needs curl in the image.
function adminCall(route, payload) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(payload || {});
    const r = http.request(
      { host: "127.0.0.1", port: ADMIN_PORT, path: route, method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${ADMIN_TOKEN}`, "content-length": Buffer.byteLength(data) } },
      (res) => { const c = []; res.on("data", (d) => c.push(d)); res.on("end", () => resolve(Buffer.concat(c).toString("utf8"))); }
    );
    r.on("error", reject);
    r.end(data);
  });
}

export const _internal = { nonces, mintNonce, checkNonce, scanUsage, safeEqual, routeAllowed, dataServer, adminServer, setKilled: (v) => { killed = v; }, RESERVE_TOKENS, ADMIN_TOKEN };

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const cmd = process.argv[2];
  if (cmd === "mint" || cmd === "revoke" || cmd === "kill") {
    // CLI talks to an already-running server's admin plane.
    const route = cmd === "mint" ? "/admin/nonce" : cmd === "revoke" ? "/admin/revoke" : "/admin/kill";
    const payload = cmd === "mint"
      ? { maxRequests: process.env.MINT_MAX_REQUESTS && Number(process.env.MINT_MAX_REQUESTS), maxTokens: process.env.MINT_MAX_TOKENS && Number(process.env.MINT_MAX_TOKENS) }
      : cmd === "revoke" ? { nonce: process.argv[3] } : { engaged: process.argv[3] !== "off" };
    adminCall(route, payload).then((out) => { process.stdout.write(out + "\n"); process.exit(0); }).catch((e) => { console.error(e.message); process.exit(1); });
  } else {
    start();
  }
}
