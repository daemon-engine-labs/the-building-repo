// arena-auth tests — QUOTA-FREE. Every assertion exercises admission / budget / kill-switch / admin
// auth, all of which resolve BEFORE any upstream call, so no Anthropic quota is touched. Run:
//   node --test runner/arena-auth/
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";

// Secrets must exist at import time (the module reads them as module-level consts).
process.env.REAL_OAUTH_TOKEN = "real-token-SHOULD-NEVER-LEAVE-PROXY";
process.env.ADMIN_TOKEN = "admin-secret";
process.env.DEFAULT_MAX_REQUESTS = "3";
process.env.DEFAULT_MAX_TOKENS = "1000";

const mod = await import("./server.mjs");
const { nonces, mintNonce, checkNonce, recordUsage, safeEqual, dataServer, adminServer, setKilled } = mod._internal;

let dataPort, adminPort;
before(async () => {
  await new Promise((r) => dataServer.listen(0, r));
  await new Promise((r) => adminServer.listen(0, r));
  dataPort = dataServer.address().port;
  adminPort = adminServer.address().port;
});
after(() => { dataServer.close(); adminServer.close(); });

function req(port, { method = "GET", path = "/v1/messages", headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const r = http.request({ host: "127.0.0.1", port, method, path, headers }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString("utf8") }));
    });
    r.on("error", reject);
    if (body) r.write(body);
    r.end();
  });
}

// ── pure admission logic ────────────────────────────────────────────────────────
test("checkNonce: unknown nonce is denied", () => {
  assert.equal(checkNonce("nope").ok, false);
});
test("checkNonce: revoked nonce is denied", () => {
  const n = mintNonce();
  nonces.get(n).revoked = true;
  assert.equal(checkNonce(n).ok, false);
});
test("checkNonce: request budget exhaustion is denied", () => {
  const n = mintNonce({ maxRequests: 2, maxTokens: 1000 });
  nonces.get(n).requests = 2;
  assert.match(checkNonce(n).reason, /request budget/);
});
test("checkNonce: token budget exhaustion is denied", () => {
  const n = mintNonce({ maxRequests: 10, maxTokens: 100 });
  nonces.get(n).tokens = 100;
  assert.match(checkNonce(n).reason, /token budget/);
});
test("recordUsage: folds input+output tokens", () => {
  const entry = { tokens: 0 };
  recordUsage(entry, JSON.stringify({ usage: { input_tokens: 10, output_tokens: 5 } }));
  assert.equal(entry.tokens, 15);
});
test("recordUsage: non-JSON body doesn't throw, leaves tokens untouched", () => {
  const entry = { tokens: 7 };
  recordUsage(entry, "event: message_start\ndata: {…}");
  assert.equal(entry.tokens, 7);
});
test("safeEqual: correct compare, length-mismatch safe", () => {
  assert.equal(safeEqual("abc", "abc"), true);
  assert.equal(safeEqual("abc", "abcd"), false);
  assert.equal(safeEqual("abc", "abd"), false);
});

// ── data plane over HTTP (all reject pre-upstream) ────────────────────────────────
test("data plane: no auth → 401", async () => {
  const r = await req(dataPort, { method: "POST" });
  assert.equal(r.status, 401);
});
test("data plane: unknown nonce → 401", async () => {
  const r = await req(dataPort, { method: "POST", headers: { authorization: "Bearer garbage" } });
  assert.equal(r.status, 401);
});
test("data plane: exhausted budget → 429 (never reaches upstream)", async () => {
  const n = mintNonce({ maxRequests: 1, maxTokens: 1000 });
  nonces.get(n).requests = 1; // already at cap
  const r = await req(dataPort, { method: "POST", headers: { authorization: `Bearer ${n}` } });
  assert.equal(r.status, 429);
});
test("data plane: response never echoes the real token", async () => {
  const r = await req(dataPort, { method: "POST", headers: { authorization: "Bearer nope" } });
  assert.ok(!r.body.includes(process.env.REAL_OAUTH_TOKEN), "real token must never appear in a response");
});

// ── admin plane ───────────────────────────────────────────────────────────────
test("admin: no token → 401", async () => {
  const r = await req(adminPort, { method: "POST", path: "/admin/nonce" });
  assert.equal(r.status, 401);
});
test("admin: mint returns a nonce that then admits on the data plane", async () => {
  const r = await req(adminPort, { method: "POST", path: "/admin/nonce", headers: { authorization: "Bearer admin-secret", "content-type": "application/json" }, body: "{}" });
  assert.equal(r.status, 200);
  const { nonce } = JSON.parse(r.body);
  assert.ok(nonce);
  assert.equal(checkNonce(nonce).ok, true);
});
test("admin: revoke then the nonce is denied", async () => {
  const mintR = await req(adminPort, { method: "POST", path: "/admin/nonce", headers: { authorization: "Bearer admin-secret", "content-type": "application/json" }, body: "{}" });
  const { nonce } = JSON.parse(mintR.body);
  await req(adminPort, { method: "POST", path: "/admin/revoke", headers: { authorization: "Bearer admin-secret", "content-type": "application/json" }, body: JSON.stringify({ nonce }) });
  assert.equal(checkNonce(nonce).ok, false);
});
test("kill switch: engaged → even a valid nonce is denied on the data plane", async () => {
  const n = mintNonce();
  setKilled(true);
  const r = await req(dataPort, { method: "POST", headers: { authorization: `Bearer ${n}` } });
  assert.equal(r.status, 401);
  setKilled(false); // lift for any later tests
});
