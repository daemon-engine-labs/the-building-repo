#!/usr/bin/env node
// arena/spend-request.mjs — the fail-closed validator for a Rail-B (card-present) spend-request.
//
// A spend-request is the ONLY affordance a build agent has for a card-present purchase: it writes
// PURE DATA into arena/spend-requests/<requestId>.json on its PR branch. This validator is the
// ENFORCING source of truth for that data (spend-request.schema.json is the human-readable spec).
//
// SECURITY POSTURE (read before changing):
//   * FAIL CLOSED, exactly like arena/heartbeat.mjs:parseDecision. Anything we cannot prove is a
//     well-formed, in-bounds request => REFUSE (exit 1). A missing field, a wrong type, an unknown
//     extra key, an out-of-range amount, an unparseable file, or an API-credit merchant all refuse.
//     Nothing here moves money — but this is the first gate, so it must never pass a doubtful request.
//   * NEVER BUY API CREDITS is enforced structurally here (defence in depth) AND at the Worker's
//     merchant allowlist. grok/codex/kimi/claude API hosts are refused regardless of what the agent
//     (possibly prompt-injected) wrote, because it's a rule, not a judgment call.
//   * No network, no secrets, no side effects. Pure data validation. Safe to run anywhere, including
//     the zero-secret sandbox runner and a PR check.
//
// Usage:
//   node arena/spend-request.mjs <path-to-request.json>     # validate one file
//   node arena/spend-request.mjs                            # validate JSON on stdin
//   import { validateSpendRequest } from "./spend-request.mjs"  # returns { ok, reason, value }

import { readFileSync } from "node:fs";
import { basename } from "node:path";

export const SCHEMA_VERSION = 1;
export const MAX_REQUEST_CENTS = 2000; // the $20 lifetime cap; the Worker re-checks the live counter.

// Merchants that are PERMANENTLY refused: the "never buy API credits" carve-out, as a structural
// rule. Matched case-insensitively as a substring of the merchant field, so `api.openai.com` and
// `openai` both refuse. The Worker enforces the positive allowlist; this is the negative floor.
const API_CREDIT_MERCHANTS = [
  "api.openai.com", "openai",
  "api.x.ai", "x.ai", "grok",
  "api.anthropic.com", "anthropic", "claude",
  "generativelanguage.googleapis.com", "gemini",
  "api.moonshot.cn", "api.moonshot.ai", "moonshot", "kimi",
];

const REQUEST_ID_RE = /^[a-z0-9][a-z0-9-]{6,63}$/;
const MERCHANT_RE = /^[a-z0-9]([a-z0-9.-]{1,98}[a-z0-9])$/;

// refuse(reason) — the single shape every rejection takes. Fail closed.
function refuse(reason) {
  return { ok: false, reason, value: null };
}

// validateSpendRequest(obj, opts) — validate an already-parsed object. Returns
// { ok:true, reason:"", value } or { ok:false, reason, value:null }. opts.filenameStem, when given,
// must equal requestId (the file is named for the id it binds a token to — no mismatch).
export function validateSpendRequest(obj, opts = {}) {
  if (obj === null || typeof obj !== "object" || Array.isArray(obj)) {
    return refuse("request is not a JSON object");
  }

  // Reject unknown keys — a strict shape means an injected extra field can't smuggle intent past us.
  const allowed = new Set([
    "schemaVersion", "requestId", "merchant", "amountCents", "item", "reason", "issue", "createdAt",
  ]);
  for (const k of Object.keys(obj)) {
    if (!allowed.has(k)) return refuse(`unknown field "${k}" (strict schema; refusing)`);
  }

  if (obj.schemaVersion !== SCHEMA_VERSION) {
    return refuse(`schemaVersion must be ${SCHEMA_VERSION}, got ${JSON.stringify(obj.schemaVersion)}`);
  }

  if (typeof obj.requestId !== "string" || !REQUEST_ID_RE.test(obj.requestId)) {
    return refuse("requestId must match ^[a-z0-9][a-z0-9-]{6,63}$");
  }
  if (opts.filenameStem !== undefined && opts.filenameStem !== obj.requestId) {
    return refuse(`filename stem "${opts.filenameStem}" != requestId "${obj.requestId}"`);
  }

  if (typeof obj.merchant !== "string" || !MERCHANT_RE.test(obj.merchant)) {
    return refuse("merchant must be a hostname/label matching ^[a-z0-9]([a-z0-9.-]{1,98}[a-z0-9])$");
  }
  const merchantLc = obj.merchant.toLowerCase();
  for (const bad of API_CREDIT_MERCHANTS) {
    if (merchantLc.includes(bad)) {
      return refuse(`merchant "${obj.merchant}" is an API-credit vendor — permanently refused (never buy API credits)`);
    }
  }

  if (!Number.isInteger(obj.amountCents) || obj.amountCents < 1 || obj.amountCents > MAX_REQUEST_CENTS) {
    return refuse(`amountCents must be an integer in [1, ${MAX_REQUEST_CENTS}], got ${JSON.stringify(obj.amountCents)}`);
  }

  if (typeof obj.item !== "string" || obj.item.trim().length < 1 || obj.item.length > 500) {
    return refuse("item must be a non-empty string <= 500 chars");
  }
  if (typeof obj.reason !== "string" || obj.reason.trim().length < 1 || obj.reason.length > 2000) {
    return refuse("reason must be a non-empty string <= 2000 chars");
  }
  if (!Number.isInteger(obj.issue) || obj.issue < 1) {
    return refuse("issue must be a positive integer (the justifying issue number)");
  }
  if (obj.createdAt !== undefined) {
    if (typeof obj.createdAt !== "string" || obj.createdAt.length < 1 || obj.createdAt.length > 40) {
      return refuse("createdAt, if present, must be a short ISO-8601 string");
    }
  }

  return { ok: true, reason: "", value: obj };
}

// validateSpendRequestText(text, opts) — parse then validate. Parse failure fails closed.
export function validateSpendRequestText(text, opts = {}) {
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (e) {
    return refuse(`unparseable JSON: ${e.message}`);
  }
  return validateSpendRequest(parsed, opts);
}

// --- CLI ----------------------------------------------------------------------------------
// Only runs when invoked directly (not on import). Exit 0 = valid, exit 1 = refused.
const invokedDirectly = process.argv[1] && import.meta.url === `file://${process.argv[1]}`;
if (invokedDirectly) {
  const path = process.argv[2];
  let text, stem;
  try {
    if (path) {
      text = readFileSync(path, "utf8");
      stem = basename(path).replace(/\.json$/i, "");
    } else {
      text = readFileSync(0, "utf8"); // stdin
    }
  } catch (e) {
    console.error(`spend-request: cannot read input: ${e.message}`);
    process.exit(1);
  }
  const res = validateSpendRequestText(text, stem !== undefined ? { filenameStem: stem } : {});
  if (!res.ok) {
    console.error(`REFUSED: ${res.reason}`);
    process.exit(1);
  }
  console.error(`OK: spend-request "${res.value.requestId}" — ${res.value.amountCents}¢ at ${res.value.merchant} (issue #${res.value.issue})`);
  process.exit(0);
}
