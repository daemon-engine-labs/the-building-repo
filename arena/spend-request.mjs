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
//     extra key, an out-of-range amount, an unparseable/oversized file, control/bidi chars in
//     human-facing text, or an API-credit merchant all refuse. Nothing here moves money — but this
//     is the first gate, so it must never pass a doubtful request.
//   * NEVER BUY API CREDITS is enforced structurally here (defence in depth) AND at the Worker's
//     merchant allowlist. Known API hosts are refused regardless of what the agent (possibly
//     prompt-injected) wrote, because it's a rule, not a judgment call.
//   * NO network, NO secrets, NO side effects. Pure data validation. Safe to run anywhere, including
//     the zero-secret sandbox runner and a PR check. IMPORTANT: in CI this validator must be run from
//     a TRUSTED ref (origin/main), never the PR branch — see .github/workflows/spend.yml. The gate is
//     only fail-closed if the JUDGE isn't the thing being judged.
//
// Usage:
//   node arena/spend-request.mjs <path-to-request.json>     # validate one file
//   node arena/spend-request.mjs                            # validate JSON on stdin
//   import { validateSpendRequest } from "./spend-request.mjs"  # returns { ok, reason, value }

import { readFileSync, statSync, realpathSync } from "node:fs";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";

export const SCHEMA_VERSION = 1;
// Per-REQUEST ceiling (cents). NOT the lifetime cap — the budget-proxy's atomic Durable Object
// counter is the lifetime total; N separate requests each ≤ this bound are individually human-gated.
// Kept equal to the $20 proxy cap so no single request can exceed the whole budget.
export const MAX_REQUEST_CENTS = 2000;
// A real spend-request is < 3KB. Cap the raw input well below that headroom so a hostile multi-MB
// file can't OOM the (disposable) runner before JSON.parse even starts — fail closed on size, first.
export const MAX_INPUT_BYTES = 65536;

// Merchants that are PERMANENTLY refused: the "never buy API credits" carve-out, as a structural
// rule. Matched case-insensitively as a SUBSTRING of the merchant field. This is DELIBERATELY broad
// and WILL over-refuse (e.g. a merchant `max.ai` trips `x.ai`) — that is the intended fail-safe
// direction: refusing a legitimate spend costs nothing. It is NOT exhaustive and is NOT the real
// gate — the Worker's POSITIVE merchant allowlist is (a request only executes at a merchant the
// Worker recognizes). This negative floor exists so an obvious API-credit buy is refused early, at
// the cheapest gate, even before the Worker sees it. Do NOT narrow this into anchored matches to
// rescue an edge merchant — a narrower denylist is a wider hole.
const API_CREDIT_MERCHANTS = [
  "openai", "chatgpt",
  "x.ai", "grok",
  "anthropic", "claude",
  "googleapis", "gemini", "generativelanguage",
  "moonshot", "kimi",
  "openrouter", "deepseek", "groq", "together.ai", "togethercomputer",
  "fireworks.ai", "mistral", "cohere", "perplexity", "replicate",
  "bedrock", "azure-api", "cognitiveservices", "anyscale", "baseten",
];

// A merchant is an ASCII host/label: dot/hyphen-separated alphanumeric labels, no leading/trailing or
// consecutive separators (so "a..b", "-a", "a-" all refuse). The Worker re-validates; this enforces
// the contract the field claims rather than pretending to.
const MERCHANT_RE = /^[a-z0-9]+([.-][a-z0-9]+)*$/;
const REQUEST_ID_RE = /^[a-z0-9][a-z0-9-]{6,63}$/;
// ISO-8601 instant, e.g. 2026-07-21T08:00:00Z or with millis/offset. Paired with Date.parse below.
const ISO8601_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?(Z|[+-]\d{2}:\d{2})$/;
// C0/C1 control chars + Unicode bidi overrides/embeddings/isolates. These are display-layer injection
// aimed at the HUMAN approval gate (the one gate that can't be fuzzed) — a merchant/amount can read
// one way in the Telegram/3DS prompt and mean another. Reject them in every human-facing string.
const UNSAFE_TEXT_RE = /[\u0000-\u001F\u007F-\u009F\u200E\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/;

// refuse(reason) — the single shape every rejection takes. Fail closed.
function refuse(reason) {
  return { ok: false, reason, value: null };
}

// A human-facing string: non-empty (trimmed), within a length bound, and free of control/bidi chars.
function checkText(field, v, max) {
  if (typeof v !== "string" || v.trim().length < 1 || v.length > max) {
    return `${field} must be a non-empty string <= ${max} chars`;
  }
  if (UNSAFE_TEXT_RE.test(v)) {
    return `${field} contains control or bidirectional-override characters (display-injection risk) — refusing`;
  }
  return null;
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

  if (typeof obj.merchant !== "string" || obj.merchant.length < 3 || obj.merchant.length > 100 || !MERCHANT_RE.test(obj.merchant)) {
    return refuse("merchant must be a 3-100 char ASCII host/label (dot/hyphen-separated alphanumeric labels, no consecutive/edge separators)");
  }
  const merchantLc = obj.merchant.toLowerCase();
  for (const bad of API_CREDIT_MERCHANTS) {
    if (merchantLc.includes(bad)) {
      return refuse(`merchant "${obj.merchant}" matches an API-credit vendor pattern ("${bad}") — permanently refused (never buy API credits)`);
    }
  }

  if (!Number.isInteger(obj.amountCents) || obj.amountCents < 1 || obj.amountCents > MAX_REQUEST_CENTS) {
    return refuse(`amountCents must be an integer in [1, ${MAX_REQUEST_CENTS}], got ${JSON.stringify(obj.amountCents)}`);
  }

  const itemErr = checkText("item", obj.item, 500);
  if (itemErr) return refuse(itemErr);
  const reasonErr = checkText("reason", obj.reason, 2000);
  if (reasonErr) return refuse(reasonErr);

  if (!Number.isInteger(obj.issue) || obj.issue < 1) {
    return refuse("issue must be a positive integer (the justifying issue number)");
  }
  if (obj.createdAt !== undefined) {
    if (typeof obj.createdAt !== "string" || !ISO8601_RE.test(obj.createdAt) || Number.isNaN(Date.parse(obj.createdAt))) {
      return refuse("createdAt, if present, must be an ISO-8601 instant (e.g. 2026-07-21T08:00:00Z)");
    }
  }

  return { ok: true, reason: "", value: obj };
}

// validateSpendRequestText(text, opts) — size-check, parse, then validate. Every step fails closed.
export function validateSpendRequestText(text, opts = {}) {
  if (typeof text !== "string") return refuse("input is not text");
  // Byte length (not char count) — a multibyte payload must be capped by what it actually weighs.
  if (Buffer.byteLength(text, "utf8") > MAX_INPUT_BYTES) {
    return refuse(`input exceeds ${MAX_INPUT_BYTES} bytes — refusing before parse`);
  }
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
// Robust entrypoint detection: compare the module's REAL path to argv[1]'s REAL path, resolving
// SYMLINKS on both sides. This matters — `import.meta.url` reports the symlink-resolved path while a
// naive `pathToFileURL(resolve(argv[1]))` does NOT resolve symlinks, so on a symlinked script path
// (e.g. the CI gate runs `node /tmp/validator.mjs`, and /tmp -> /private/tmp on macOS) the two would
// disagree, the CLI would silently no-op, and the gate would exit 0 on a KNOWN-BAD request — a
// fail-OPEN a cage-match caught. realpathSync on both sides removes that whole class. Fail closed if
// either path can't be realpath'd.
function invokedDirectlyCheck() {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]);
  } catch {
    return false;
  }
}
const invokedDirectly = invokedDirectlyCheck();
if (invokedDirectly) {
  const path = process.argv[2];
  let text, stem;
  try {
    if (path) {
      // Refuse oversized files by their on-disk size BEFORE reading them into memory — the read
      // itself is the OOM risk, so the size gate must precede it.
      const bytes = statSync(path).size;
      if (bytes > MAX_INPUT_BYTES) {
        console.error(`REFUSED: file is ${bytes} bytes (> ${MAX_INPUT_BYTES}) — refusing before read`);
        process.exit(1);
      }
      text = readFileSync(path, "utf8");
      stem = basename(path).replace(/\.json$/i, "");
    } else {
      text = readFileSync(0, "utf8"); // stdin (CI always passes a path; stdin is for local use)
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
