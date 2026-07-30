#!/usr/bin/env node
// arena-auth — the sandbox's spend trust boundary.
//
// WHY THIS EXISTS (see docs/crucible/build-sandbox/DESIGN.md, finding T1):
// An untrusted build needs an LLM, an LLM needs a credential, but the sandbox is the place a
// credential must NOT exist — a prompt-injected agent could write it into the diff → artifact → PR
// (a network-independent exfil the egress wall can't see). So the real Anthropic token NEVER touches
// the sandbox. The sandbox holds only a per-job NONCE, which it sends as its Authorization. This
// proxy validates the nonce, strips it, injects the real token, and forwards ONLY to
// api.anthropic.com. The token is unexfiltratable because it is never on the runner.
//
// The nonce is not a static "dummy": it is single-use-per-job, BUDGET-CAPPED, and REVOKABLE. Tesla's
// cage-match catch (F1) was that a validated dummy is itself a spend-credential — true, but a leaked
// nonce burns at most ONE job's capped budget and can be killed, not a reusable year-lived token.
// That bounded residual is the accepted tradeoff.
//
// TWO listeners, deliberately separate:
//   - DATA  (DATA_PORT): what the sandbox reaches over arena-internal. Proxies to Anthropic.
//   - ADMIN (ADMIN_PORT): mint/revoke nonces + kill switch. ADMIN_TOKEN-gated. The sandbox must NOT
//     be able to route to this port (bind it to the egress side only) — it is the control plane.
//
// Dependency-free (node built-ins only), matching arena/*.mjs.

import http from "node:http";
import https from "node:https";
import { randomBytes, timingSafeEqual } from "node:crypto";

// ── config ────────────────────────────────────────────────────────────────────
const REAL_TOKEN = process.env.REAL_OAUTH_TOKEN || "";
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || "";
const DATA_PORT = parseInt(process.env.DATA_PORT || "8080", 10);
const ADMIN_PORT = parseInt(process.env.ADMIN_PORT || "8081", 10);
// The DATA plane binds 0.0.0.0 so the sandbox can reach it over arena-internal.
// The ADMIN plane binds container-LOOPBACK by default: within a single docker network there is NO
// port-level isolation, so an admin listener on 0.0.0.0 would be reachable by the sandbox on the
// container's arena-internal IP (and a `-p 127.0.0.1:…` host mapping does NOT help — in-network
// traffic hits the container IP directly, bypassing the mapping). Loopback-only means the sandbox,
// which reaches the container via its arena-internal IP (never 127.0.0.1), cannot route to admin at
// all. Minting is done via `docker exec arena-auth …` (host docker access ⇒ privileged). Override
// ADMIN_BIND only with a deliberate, understood topology.
const DATA_BIND = process.env.DATA_BIND || "0.0.0.0";
const ADMIN_BIND = process.env.ADMIN_BIND || "127.0.0.1";
const UPSTREAM_HOST = "api.anthropic.com";
// Default per-nonce budget: request count. Token accounting is additive on top (see recordUsage).
const DEFAULT_MAX_REQUESTS = parseInt(process.env.DEFAULT_MAX_REQUESTS || "40", 10);
const DEFAULT_MAX_TOKENS = parseInt(process.env.DEFAULT_MAX_TOKENS || "300000", 10);
// The OAuth beta header the Direct-Bearer path requires (see global CLAUDE.md).
const OAUTH_BETA = "oauth-2025-04-20";

// ── nonce registry (in-memory; a proxy restart revokes every live nonce — fail-closed) ──────────
// nonce -> { requests, maxRequests, tokens, maxTokens, revoked }
const nonces = new Map();
let killed = false; // global kill switch

function mintNonce({ maxRequests = DEFAULT_MAX_REQUESTS, maxTokens = DEFAULT_MAX_TOKENS } = {}) {
  const nonce = randomBytes(24).toString("base64url");
  nonces.set(nonce, { requests: 0, maxRequests, tokens: 0, maxTokens, revoked: false });
  return nonce;
}

// Constant-time compare that never throws on length mismatch (timingSafeEqual requires equal length).
function safeEqual(a, b) {
  const ab = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

// Returns { ok, reason, entry } — the single admission decision for a data request.
function checkNonce(nonce) {
  if (killed) return { ok: false, reason: "kill switch engaged" };
  if (!nonce) return { ok: false, reason: "no nonce" };
  const entry = nonces.get(nonce);
  if (!entry) return { ok: false, reason: "unknown nonce" };
  if (entry.revoked) return { ok: false, reason: "revoked nonce" };
  if (entry.requests >= entry.maxRequests) return { ok: false, reason: "request budget exhausted" };
  if (entry.tokens >= entry.maxTokens) return { ok: false, reason: "token budget exhausted" };
  return { ok: true, entry };
}

// Fold Anthropic usage (input+output tokens) back into the nonce's running total.
function recordUsage(entry, upstreamBody) {
  try {
    const j = JSON.parse(upstreamBody);
    const u = j.usage || {};
    const used = (u.input_tokens || 0) + (u.output_tokens || 0);
    if (used > 0) entry.tokens += used;
  } catch {
    /* streaming / non-JSON body — request-count cap still bounds it */
  }
}

// Bearer token from an Authorization header, or null.
function bearerFrom(req) {
  const h = req.headers["authorization"] || "";
  const m = /^Bearer\s+(.+)$/i.exec(h);
  return m ? m[1] : null;
}

// ── DATA plane ──────────────────────────────────────────────────────────────────
// Validates the nonce, injects the real token, forwards ONLY to api.anthropic.com, scrubs response
// headers, and meters usage. This is the only surface the sandbox can reach.
const dataServer = http.createServer((req, res) => {
  const nonce = bearerFrom(req);
  const verdict = checkNonce(nonce);
  if (!verdict.ok) {
    res.writeHead(verdict.reason.includes("budget") ? 429 : 401, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { type: "arena_auth_denied", message: verdict.reason } }));
    return;
  }
  const entry = verdict.entry;
  entry.requests += 1; // count on admission so a hung upstream still consumes budget

  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const body = Buffer.concat(chunks);
    // Rebuild headers: DROP any client-supplied auth, PIN host to Anthropic, INJECT the real token.
    const headers = { ...req.headers };
    delete headers["authorization"];
    delete headers["x-api-key"];
    headers["host"] = UPSTREAM_HOST;
    headers["authorization"] = `Bearer ${REAL_TOKEN}`;
    headers["anthropic-beta"] = headers["anthropic-beta"]
      ? `${headers["anthropic-beta"]},${OAUTH_BETA}`
      : OAUTH_BETA;

    const up = https.request(
      { hostname: UPSTREAM_HOST, port: 443, path: req.url, method: req.method, headers },
      (upRes) => {
        // Scrub hop-by-hop / identifying upstream headers before they reach the sandbox.
        const safe = { ...upRes.headers };
        delete safe["set-cookie"];
        const upChunks = [];
        upRes.on("data", (c) => upChunks.push(c));
        upRes.on("end", () => {
          const upBody = Buffer.concat(upChunks);
          recordUsage(entry, upBody.toString("utf8"));
          res.writeHead(upRes.statusCode, safe);
          res.end(upBody);
        });
      }
    );
    up.on("error", (e) => {
      res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { type: "arena_auth_upstream", message: e.message } }));
    });
    up.end(body);
  });
});

// ── ADMIN plane ─────────────────────────────────────────────────────────────────
// ADMIN_TOKEN-gated. Mints/revokes nonces and toggles the kill switch. MUST NOT be reachable from
// the sandbox (bind to the egress side; the sandbox lives on arena-internal only).
const adminServer = http.createServer((req, res) => {
  const auth = bearerFrom(req);
  if (!ADMIN_TOKEN || !safeEqual(auth, ADMIN_TOKEN)) {
    res.writeHead(401, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "admin auth required" }));
    return;
  }
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    let payload = {};
    try { payload = chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {}; } catch { /* {} */ }

    if (req.method === "POST" && req.url === "/admin/nonce") {
      const nonce = mintNonce(payload);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ nonce, maxRequests: nonces.get(nonce).maxRequests, maxTokens: nonces.get(nonce).maxTokens }));
      return;
    }
    if (req.method === "POST" && req.url === "/admin/revoke") {
      const entry = nonces.get(payload.nonce);
      if (entry) entry.revoked = true;
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ revoked: Boolean(entry) }));
      return;
    }
    if (req.method === "POST" && req.url === "/admin/kill") {
      killed = payload.engaged !== false; // default true; explicit {engaged:false} lifts it
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ killed }));
      return;
    }
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "unknown admin route" }));
  });
});

// ── startup: fail closed on missing secrets ───────────────────────────────────────
export function start() {
  if (!REAL_TOKEN) { console.error("[arena-auth] REAL_OAUTH_TOKEN not set — refusing to start."); process.exit(2); }
  if (!ADMIN_TOKEN) { console.error("[arena-auth] ADMIN_TOKEN not set — refusing to start (admin plane would be open)."); process.exit(2); }
  dataServer.listen(DATA_PORT, DATA_BIND, () => console.error(`[arena-auth] data plane on ${DATA_BIND}:${DATA_PORT} → ${UPSTREAM_HOST}`));
  adminServer.listen(ADMIN_PORT, ADMIN_BIND, () => console.error(`[arena-auth] admin plane on ${ADMIN_BIND}:${ADMIN_PORT} (ADMIN_TOKEN-gated, loopback-only by default)`));
}

// Exported for tests (no listen); started for real when run as the entrypoint.
export const _internal = { nonces, mintNonce, checkNonce, recordUsage, safeEqual, dataServer, adminServer, setKilled: (v) => { killed = v; } };

if (import.meta.url === `file://${process.argv[1]}`) start();
