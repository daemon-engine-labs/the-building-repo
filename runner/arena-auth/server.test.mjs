// arena-auth tests — QUOTA-FREE. Every assertion resolves BEFORE any upstream call (route/nonce/body
// rejections) or exercises pure functions (usage parsing, mint clamp), so no Anthropic quota is
// touched. Run: node --test runner/arena-auth/server.test.mjs
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";

process.env.REAL_OAUTH_TOKEN = "real-token-SHOULD-NEVER-LEAVE-PROXY";
process.env.ADMIN_TOKEN = "admin-secret";
process.env.DEFAULT_MAX_REQUESTS = "3";
process.env.DEFAULT_MAX_TOKENS = "1000000";
process.env.MAX_BODY_BYTES = "1024";
process.env.CEIL_MAX_REQUESTS = "200";

const mod = await import("./server.mjs");
const { nonces, mintNonce, checkNonce, scanUsage, safeEqual, routeAllowed, dataServer, adminServer, setKilled, RESERVE_TOKENS } = mod._internal;

let dataPort, adminPort;
before(async () => {
  await new Promise((r) => dataServer.listen(0, "127.0.0.1", r));
  await new Promise((r) => adminServer.listen(0, "127.0.0.1", r));
  dataPort = dataServer.address().port;
  adminPort = adminServer.address().port;
});
after(() => { dataServer.close(); adminServer.close(); });

function req(port, { method = "POST", path = "/v1/messages", headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    // Always frame with content-length (a real HTTP client does) — a bodyless POST with no length
    // leaves the request unterminated and can race an early denial into ECONNRESET.
    const fullHeaders = { "content-length": body ? Buffer.byteLength(body) : 0, ...headers };
    const r = http.request({ host: "127.0.0.1", port, method, path, headers: fullHeaders }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString("utf8") }));
    });
    r.on("error", reject);
    if (body) r.write(body);
    r.end();
  });
}

// ── route allowlist (default-deny) ────────────────────────────────────────────────
test("routeAllowed: POST /v1/messages allowed; GET not; unknown path not", () => {
  assert.equal(routeAllowed("POST", "/v1/messages"), true);
  assert.equal(routeAllowed("POST", "/v1/messages/count_tokens"), true);
  assert.equal(routeAllowed("GET", "/v1/models"), true);
  assert.equal(routeAllowed("GET", "/v1/messages"), false);      // wrong method
  assert.equal(routeAllowed("POST", "/v1/organizations"), false); // account-enumeration path
  assert.equal(routeAllowed("DELETE", "/v1/messages"), false);
});
test("routeAllowed: prefix is boundary-anchored — /v1/messagesX must NOT slip", () => {
  assert.equal(routeAllowed("POST", "/v1/messages-evil"), false);
  assert.equal(routeAllowed("POST", "/v1/messagesX"), false);
  assert.equal(routeAllowed("GET", "/v1/models-secret"), false);
  assert.equal(routeAllowed("POST", "/v1/messages?beta=1"), true); // query is fine
});
test("data plane: disallowed route → 403 (before nonce check)", async () => {
  const r = await req(dataPort, { method: "POST", path: "/v1/organizations", headers: { authorization: "Bearer whatever" } });
  assert.equal(r.status, 403);
});

// ── pure admission logic (reservation-aware) ──────────────────────────────────────
test("checkNonce: unknown nonce denied", () => { assert.equal(checkNonce("nope").ok, false); });
test("checkNonce: revoked denied", () => { const n = mintNonce(); nonces.get(n).revoked = true; assert.equal(checkNonce(n).ok, false); });
test("checkNonce: expired denied (server TTL is the fail-closed backstop to client revoke)", () => {
  const n = mintNonce();
  assert.equal(checkNonce(n).ok, true);          // fresh nonce admits
  nonces.get(n).expiresAt = Date.now() - 1;      // simulate TTL elapsed (host killed before revoke)
  const v = checkNonce(n);
  assert.equal(v.ok, false);
  assert.match(v.reason, /expired/);
});
test("checkNonce: request budget exhaustion denied", () => {
  const n = mintNonce({ maxRequests: 2, maxTokens: 1000000 }); nonces.get(n).requests = 2;
  assert.match(checkNonce(n).reason, /request budget/);
});
test("checkNonce: reservation blocks when tokens+reserved+RESERVE would exceed cap", () => {
  const n = mintNonce({ maxRequests: 99, maxTokens: RESERVE_TOKENS + 10 });
  nonces.get(n).reserved = 20; // one in-flight; a second admission would exceed
  assert.match(checkNonce(n).reason, /token budget/);
});

// ── SSE + JSON usage metering ─────────────────────────────────────────────────────
test("scanUsage: whole-JSON body", () => {
  const acc = scanUsage(JSON.stringify({ usage: { input_tokens: 10, output_tokens: 5 } }), { input: 0, output: 0 });
  assert.deepEqual(acc, { input: 10, output: 5 });
});
test("scanUsage: SSE stream (message_start input, message_delta cumulative output)", () => {
  const acc = { input: 0, output: 0 };
  scanUsage('event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":42}}}\n', acc);
  scanUsage('event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":7}}\n', acc);
  scanUsage('event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":19}}\n', acc);
  assert.deepEqual(acc, { input: 42, output: 19 }); // output is cumulative → last wins
});

// ── mint clamping ─────────────────────────────────────────────────────────────────
test("mint: attacker-shaped budget clamped to server ceiling", () => {
  const n = mintNonce({ maxRequests: 999999, maxTokens: 999999999999 });
  assert.equal(nonces.get(n).maxRequests, 200); // CEIL_MAX_REQUESTS
});

// ── data plane over HTTP (all reject pre-upstream) ────────────────────────────────
test("data plane: no auth on allowed route → 401", async () => {
  assert.equal((await req(dataPort)).status, 401);
});
test("data plane: unknown nonce → 401", async () => {
  assert.equal((await req(dataPort, { headers: { authorization: "Bearer garbage" } })).status, 401);
});
test("data plane: exhausted request budget → 429", async () => {
  const n = mintNonce({ maxRequests: 1, maxTokens: 1000000 }); nonces.get(n).requests = 1;
  assert.equal((await req(dataPort, { headers: { authorization: `Bearer ${n}` } })).status, 429);
});
test("data plane: oversized body → 413 (never reaches upstream)", async () => {
  const n = mintNonce();
  const big = "x".repeat(2048); // > MAX_BODY_BYTES (1024)
  const r = await req(dataPort, { headers: { authorization: `Bearer ${n}`, "content-type": "application/json" }, body: big });
  assert.equal(r.status, 413);
});
test("data plane: denial response never echoes the real token", async () => {
  const r = await req(dataPort, { headers: { authorization: "Bearer nope" } }); // allowed route, bad nonce → 401
  assert.equal(r.status, 401);
  assert.ok(!r.body.includes(process.env.REAL_OAUTH_TOKEN));
});

// ── admin plane ───────────────────────────────────────────────────────────────
test("admin: no token → 401", async () => {
  assert.equal((await req(adminPort, { path: "/admin/nonce" })).status, 401);
});
test("admin: mint returns a nonce that admits on the data plane", async () => {
  const r = await req(adminPort, { path: "/admin/nonce", headers: { authorization: "Bearer admin-secret", "content-type": "application/json" }, body: "{}" });
  assert.equal(r.status, 200);
  const { nonce } = JSON.parse(r.body);
  assert.equal(checkNonce(nonce).ok, true);
});
test("admin: revoke then denied", async () => {
  const m = await req(adminPort, { path: "/admin/nonce", headers: { authorization: "Bearer admin-secret", "content-type": "application/json" }, body: "{}" });
  const { nonce } = JSON.parse(m.body);
  await req(adminPort, { path: "/admin/revoke", headers: { authorization: "Bearer admin-secret", "content-type": "application/json" }, body: JSON.stringify({ nonce }) });
  assert.equal(checkNonce(nonce).ok, false);
});
test("kill switch: engaged → valid nonce denied", async () => {
  const n = mintNonce(); setKilled(true);
  assert.equal((await req(dataPort, { headers: { authorization: `Bearer ${n}` } })).status, 401);
  setKilled(false);
});
test("admin: malformed JSON → 400", async () => {
  const r = await req(adminPort, { path: "/admin/nonce", headers: { authorization: "Bearer admin-secret", "content-type": "application/json" }, body: "{not json" });
  assert.equal(r.status, 400);
});
test("admin: oversized body → 413", async () => {
  const r = await req(adminPort, { path: "/admin/nonce", headers: { authorization: "Bearer admin-secret" }, body: "x".repeat(2048) });
  assert.equal(r.status, 413);
});
test("scanUsage: a data line reassembled from two halves meters correctly", () => {
  // Simulates the handler's lineBuf: the record only scans once COMPLETE.
  const acc = { input: 0, output: 0 };
  let lineBuf = 'event: message_delta\ndata: {"usage":{"output_';
  scanUsage(lineBuf.slice(0, lineBuf.lastIndexOf("\n")), acc); // only the complete first line
  assert.equal(acc.output, 0); // partial data: line not yet parsed
  lineBuf = lineBuf.slice(lineBuf.lastIndexOf("\n") + 1) + 'tokens":88}}\n';
  scanUsage(lineBuf, acc);
  assert.equal(acc.output, 88); // reassembled → metered
});
test("safeEqual: correct + length-mismatch safe", () => {
  assert.equal(safeEqual("abc", "abc"), true);
  assert.equal(safeEqual("abc", "abcd"), false);
  assert.equal(safeEqual("abc", "abd"), false);
});
