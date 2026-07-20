// arena/spend-request.test.mjs — fail-closed coverage for the spend-request validator.
// Run: node --test arena/spend-request.test.mjs
//
// Covers BOTH surfaces, because the gate exercises both and a bug in either is a fail-open:
//   1. validateSpendRequest() — the importable function (unit cases).
//   2. the CLI entrypoint — run as a real subprocess on a real file, since the CI workflow invokes
//      `node arena/spend-request.mjs <file>` and an imported-function-only test is blind to a dead
//      entrypoint (the exact self-referential blindness a cage-match caught on the first cut).

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { writeFileSync, mkdtempSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { validateSpendRequest, validateSpendRequestText, MAX_INPUT_BYTES } from "./spend-request.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const CLI = join(HERE, "spend-request.mjs");
const base = () => ({
  schemaVersion: 1, requestId: "buy-captcha-001", merchant: "2captcha.com",
  amountCents: 50, item: "one hCaptcha solve", reason: "build for #42 hit an hCaptcha wall", issue: 42,
});

test("valid baseline passes", () => {
  assert.equal(validateSpendRequest(base()).ok, true);
});

const rejects = {
  "over cap": { amountCents: 2001 },
  "zero amount": { amountCents: 0 },
  "negative amount": { amountCents: -5 },
  "float amount": { amountCents: 1.5 },
  "string amount": { amountCents: "50" },
  "NaN amount": { amountCents: NaN },
  "bad schemaVersion": { schemaVersion: 2 },
  "bad requestId (uppercase)": { requestId: "UP_CASE" },
  "bad requestId (too short)": { requestId: "abc" },
  "merchant consecutive dots": { merchant: "a..b.com" },
  "merchant leading hyphen": { merchant: "-evil.com" },
  "merchant non-ascii": { merchant: "café.com" },
  "empty item": { item: "" },
  "oversized item": { item: "x".repeat(501) },
  "missing issue": { issue: undefined },
  "zero issue": { issue: 0 },
  "bad createdAt": { createdAt: "yesterday" },
};
for (const [name, patch] of Object.entries(rejects)) {
  test(`rejects: ${name}`, () => {
    const o = { ...base(), ...patch };
    for (const k of Object.keys(patch)) if (patch[k] === undefined) delete o[k];
    assert.equal(validateSpendRequest(o).ok, false, `${name} should refuse`);
  });
}

test("rejects unknown field (strict shape)", () => {
  assert.equal(validateSpendRequest({ ...base(), spend: true }).ok, false);
});

test("rejects prototype-pollution keys", () => {
  for (const t of ['{"__proto__":{"x":1}}', '{"constructor":1}']) {
    const merged = JSON.stringify({ ...base(), ...JSON.parse(t) });
    assert.equal(validateSpendRequestText(merged).ok, false, `${t} should refuse`);
  }
});

test("rejects API-credit merchants (broad denylist)", () => {
  for (const m of ["api.openai.com", "grok-billing.x.ai", "openrouter.ai", "api.deepseek.com", "api.groq.com", "console.anthropic.com"]) {
    assert.equal(validateSpendRequest({ ...base(), merchant: m }).ok, false, `${m} should refuse`);
  }
});

test("rejects control/bidi chars in human-facing text", () => {
  for (const bad of ["\u0000", "\u202e", "\u200f", "\ufeff"]) {
    assert.equal(validateSpendRequest({ ...base(), item: `pay${bad}me` }).ok, false);
    assert.equal(validateSpendRequest({ ...base(), reason: `x${bad}y` }).ok, false);
  }
});

test("rejects oversized and non-string input", () => {
  assert.equal(validateSpendRequestText(`{"x":"${"a".repeat(MAX_INPUT_BYTES)}"}`).ok, false);
  assert.equal(validateSpendRequestText(12345).ok, false);
  assert.equal(validateSpendRequestText("{not json").ok, false);
});

test("accepts a valid createdAt", () => {
  assert.equal(validateSpendRequest({ ...base(), createdAt: "2026-07-21T08:00:00Z" }).ok, true);
});

// --- CLI wire: the surface the CI gate actually runs ---
const runCli = (file) => {
  try {
    execFileSync(process.execPath, [CLI, file], { stdio: "pipe" });
    return 0;
  } catch (e) {
    return e.status ?? 1;
  }
};

test("CLI exits 0 on a valid request file", () => {
  const dir = mkdtempSync(join(tmpdir(), "sr-"));
  const f = join(dir, "buy-captcha-001.json"); // stem must equal requestId
  writeFileSync(f, JSON.stringify(base()));
  assert.equal(runCli(f), 0);
});

test("CLI exits 1 on a known-bad request file (fail-closed)", () => {
  const dir = mkdtempSync(join(tmpdir(), "sr-"));
  const f = join(dir, "evil.json");
  writeFileSync(f, JSON.stringify({ ...base(), requestId: "evil", merchant: "api.openai.com", amountCents: 999999 }));
  assert.equal(runCli(f), 1);
});

test("CLI exits 1 when filename stem != requestId", () => {
  const dir = mkdtempSync(join(tmpdir(), "sr-"));
  const f = join(dir, "wrong-name.json");
  writeFileSync(f, JSON.stringify(base())); // requestId is buy-captcha-001, filename is wrong-name
  assert.equal(runCli(f), 1);
});

test("CLI exits 1 on a relative path (proves entrypoint fires with relative argv)", () => {
  // The CI workflow passes a relative path. This guards the invokedDirectly regression class.
  const rel = "arena/spend-request.schema.json"; // exists, but is not a valid request → must refuse
  assert.equal(runCli(rel), 1);
});

test("CLI fires through a SYMLINKED script path (the fail-open a cage-match caught)", () => {
  // The gate runs `node /tmp/validator.mjs`, and /tmp -> /private/tmp on macOS. If entrypoint
  // detection doesn't resolve symlinks, the CLI silently no-ops and a KNOWN-BAD request exits 0.
  // Run the validator through a symlink and assert it still refuses a bad request.
  const dir = mkdtempSync(join(tmpdir(), "sr-sym-"));
  const link = join(dir, "validator-link.mjs");
  symlinkSync(CLI, link);
  const bad = join(dir, "evil.json");
  writeFileSync(bad, JSON.stringify({ ...base(), requestId: "evil", merchant: "api.openai.com", amountCents: 999999 }));
  try {
    execFileSync(process.execPath, [link, bad], { stdio: "pipe" });
    assert.fail("known-bad request passed through a symlinked validator — FAIL OPEN");
  } catch (e) {
    assert.equal(e.status, 1, "symlinked validator must still refuse (exit 1)");
  }
});
