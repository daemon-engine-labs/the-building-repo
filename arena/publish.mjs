#!/usr/bin/env node
// arena/publish.mjs — the DEFAULT-DENY gate on an untrusted, sandbox-produced patch, BEFORE the
// privileged publisher (publish.yml) may `git apply` it and open a PR.
//
// WHY THIS EXISTS (see docs/crucible/build-sandbox/DESIGN.md, finding T3):
// The untrusted `build-sandbox` path runs an agent on hostile issue text and uploads whatever diff it
// produces as an artifact. `git apply` "never executes" a patch — but MERGE is the execution scheduler
// for the NEXT privileged build: a patch that rewrites arena/run.mjs, agents/*.md, .github/**, the
// allowlist, or a lockfile, merged under review fatigue, poisons the next run that DOES hold real
// tokens. So the control is INVERTED to a default-deny path allowlist: an untrusted proposal may touch
// ONLY explicitly-listed product paths; ANY path outside — or any dangerous mode (symlink, submodule,
// executable bit, binary) — is REJECTED and never becomes a PR. CODEOWNERS is the backstop, not the
// primary control (it is advisory here — branch protection does not enforce it).
//
// This module is PURE VALIDATION: it parses a unified diff and returns a verdict. It runs no agent,
// holds no secret, and performs no git/network side effect — publish.yml does the apply+PR only when
// this returns ok. Fail-CLOSED: anything unparseable or ambiguous is rejected, never waved through.
//
// Dependency-free (node built-ins only), matching arena/*.mjs.

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

// Default-deny product allowlist: the ONLY path prefixes an untrusted proposal may touch. Everything
// else is privilege-escalation surface (it drives or gates a privileged build) and is rejected. This
// is deliberately SMALL — this repo is mostly machinery — and grows only as real, non-privileged
// product directories are added. Prefixes end in "/" so "docs/" cannot match a sibling like "docsx/".
export const PRODUCT_ALLOW = ["docs/"];

// Hard byte cap on the whole patch (defense in depth beside the workflow's own streaming cap).
export const MAX_PATCH_BYTES = 300_000;

// A path is allowed iff it sits under an allowed prefix AND is a clean relative path (no traversal,
// no absolute, no NUL). We normalise nothing — we REJECT anything that isn't already clean, because a
// path needing normalisation is exactly the evasion surface.
export function pathAllowed(p, allow = PRODUCT_ALLOW) {
  if (typeof p !== "string" || p.length === 0) return false;
  if (p.includes("\0")) return false;
  if (p.startsWith("/")) return false;                 // absolute
  if (p.includes("\\")) return false;                  // backslash (Windows sep / escape shape) — refuse
  if (p.includes("//")) return false;                  // empty segment — refuse (odd path shape)
  if (p === "." || p.startsWith("./") || p.includes("/./")) return false; // single-dot segment — refuse
  if (p === ".." || p.startsWith("../") || p.includes("/../") || p.endsWith("/..")) return false; // traversal
  return allow.some((prefix) => p.startsWith(prefix));
}

// C-unquote a git diff path. Git quotes paths with special chars as C-strings ("a\tb"); a quoted path is
// itself suspicious in an untrusted patch, so we DECODE it (to check it honestly) — the caller still runs
// the result through pathAllowed. Used for EVERY path-bearing token (diff --git, rename, copy) so the
// checks are symmetric (cage-match — Tesla: rename/copy previously skipped this).
function unquote(raw) {
  let s = raw;
  if (s.length >= 2 && s[0] === '"' && s[s.length - 1] === '"') {
    s = s.slice(1, -1).replace(/\\([\\"ntrbfav0]|[0-7]{1,3}|x[0-9a-fA-F]{2})/g, (m, e) => {
      const map = { n: "\n", t: "\t", r: "\r", b: "\b", f: "\f", a: "\x07", v: "\v", "0": "\0", "\\": "\\", '"': '"' };
      if (e in map) return map[e];
      if (e[0] === "x") return String.fromCharCode(parseInt(e.slice(1), 16));
      return String.fromCharCode(parseInt(e, 8));
    });
  }
  return s;
}
// Unquote AND strip the a/ or b/ prefix (for diff --git tokens, which carry it). /dev/null → null.
function stripPrefix(raw) {
  let s = unquote(raw);
  if (s === "/dev/null") return null;                  // add/delete sentinel — carries no real path
  if (s.startsWith("a/") || s.startsWith("b/")) s = s.slice(2);
  return s;
}

// Parse a unified git diff into the set of touched paths + any dangerous flags. Conservative by
// construction: every path-bearing line contributes to the path set, and any mode/marker we recognise
// as dangerous is flagged. Returns { paths:Set, flags:{...}, parseError:string|null }.
export function parsePatch(text) {
  const paths = new Set();
  const flags = { badMode: null, submodule: false, binary: false };
  let sawDiffHeader = false;
  let parseError = null;

  const add = (raw) => { const p = stripPrefix(raw); if (p !== null) paths.add(p); };
  // rename/copy paths carry no a/ b/ prefix but CAN be C-quoted — unquote them (Tesla).
  const addBare = (raw) => paths.add(unquote(raw));
  // Split on \r?\n, NOT just \n: a CRLF patch would otherwise leave a trailing \r that breaks the
  // $-anchored mode regexes below — a symlink/submodule/exec line could slip the gate while every path
  // still read as docs/ (a real bypass). Normalising line endings closes it.
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // `diff --git a/X b/Y` — the authoritative pair. Split on " b/" is unsafe for spaces; git always
    // emits a/ and b/ prefixes, so we take the two prefixed tokens conservatively.
    if (line.startsWith("diff --git ")) {
      sawDiffHeader = true;
      const m = /^diff --git (.+) (b\/.+|"b\/.+")$/.exec(line);
      if (m) { add(m[1]); add(m[2]); }
      else parseError = parseError || `unparseable diff header: ${line.slice(0, 120)}`;
      continue;
    }
    // NOTE: we deliberately DO NOT parse `--- `/`+++ ` lines. The `diff --git a/X b/Y` header already
    // carries every touched path unambiguously, and a header line cannot be forged by hunk content (a
    // content line always bears a +/-/space marker, so it can't start with `diff --git ` at column 0).
    // But a hunk ADDED line whose content begins with `++ b/arena/x` renders as `+++ b/arena/x` — if we
    // treated that as a header we'd falsely reject a legit docs patch that merely SHOWS a diff (this
    // repo's docs are full of them). Paths come from `diff --git` + rename/copy only (cage-match — Carnot).
    if (line.startsWith("rename from ") || line.startsWith("copy from ")) { addBare(line.replace(/^(rename|copy) from /, "")); continue; }
    if (line.startsWith("rename to ") || line.startsWith("copy to ")) { addBare(line.replace(/^(rename|copy) to /, "")); continue; }
    // DEFAULT-DENY modes (mirror the path philosophy — Tesla: a denylist of a few known-bad modes let
    // 100700/100711/other +x variants slip). A line that SETS a mode (new file / changed-to mode) may
    // ONLY set 100644 (a regular non-exec file). Anything else — symlink 120000, submodule 160000, any
    // executable/other bits — is refused. `old mode`/`deleted file mode` describe prior/removed state
    // and are harmless, so they are not restricted.
    const mSet = /^(new file mode|new mode) ([0-7]{6})$/.exec(line);
    if (mSet && mSet[2] !== "100644") flags.badMode = mSet[2];
    // git ALSO carries the file mode on the `index` line for a content-modified file whose mode is
    // UNCHANGED (`index <old>..<new> <mode>`). new file / mode-change cases emit no trailing mode here,
    // so this is the remaining mode surface — admit it too, same allowlist (cage-match r2 — Tesla:
    // "incomplete admission of what git actually emits"). A normal docs edit is `…100644` → not flagged.
    const mIdx = /^index [0-9a-f]+\.\.[0-9a-f]+ ([0-7]{6})$/.exec(line);
    if (mIdx && mIdx[1] !== "100644") flags.badMode = mIdx[1];
    if (/^Subproject commit [0-9a-f]{7,40}$/.test(line)) flags.submodule = true;
    // Binary content — either form git emits.
    if (line.startsWith("GIT binary patch")) flags.binary = true;
    if (/^Binary files .* differ$/.test(line)) flags.binary = true;
  }
  if (!sawDiffHeader && text.trim().length > 0) parseError = parseError || "no `diff --git` header found in a non-empty patch";
  return { paths, flags, parseError };
}

// The verdict. ok:true ONLY when the patch is non-empty, cleanly parsed, touches nothing outside the
// allowlist, and carries no dangerous mode. Any other state → ok:false with human-readable reasons.
export function validatePatch(text, { allow = PRODUCT_ALLOW, maxBytes = MAX_PATCH_BYTES } = {}) {
  const reasons = [];
  const bytes = Buffer.byteLength(text, "utf8");
  if (bytes === 0 || text.trim().length === 0) {
    return { ok: false, empty: true, reasons: ["patch is empty — nothing to publish"], paths: [], rejected: [] };
  }
  if (bytes > maxBytes) reasons.push(`patch is ${bytes} bytes (> ${maxBytes} cap)`);

  const { paths, flags, parseError } = parsePatch(text);
  if (parseError) reasons.push(`unparseable patch (fail-closed): ${parseError}`);
  if (flags.badMode) {
    const named = { "120000": "SYMLINK", "160000": "SUBMODULE/gitlink", "100755": "EXECUTABLE" }[flags.badMode];
    reasons.push(`patch sets a non-regular file mode ${flags.badMode}${named ? ` (${named})` : ""} — only 100644 is allowed`);
  }
  if (flags.submodule) reasons.push("patch creates/alters a SUBMODULE / gitlink — refused");
  if (flags.binary) reasons.push("patch contains BINARY content — refused (untrusted proposals are TEXT-ONLY; media ships via the trusted path)");

  const rejected = [...paths].filter((p) => !pathAllowed(p, allow)).sort();
  if (rejected.length) {
    reasons.push(
      `patch touches ${rejected.length} path(s) outside the product allowlist [${allow.join(", ")}]: ` +
        rejected.slice(0, 20).join(", ") + (rejected.length > 20 ? " …" : "")
    );
  }
  return { ok: reasons.length === 0, empty: false, reasons, paths: [...paths].sort(), rejected };
}

// CLI: `node arena/publish.mjs <patch-file>` → prints a JSON verdict to stdout, exit 0 iff ok.
// publish.yml calls this and applies+PRs only on ok:true; on ok:false it comments the issue and stops.
export const _internal = { pathAllowed, parsePatch, stripPrefix };

if (import.meta.url === pathToFileURL(process.argv[1] || "").href) {
  const file = process.argv[2];
  if (!file) { console.error("usage: node arena/publish.mjs <patch-file>"); process.exit(2); }
  let text = "";
  try { text = readFileSync(file, "utf8"); } catch (e) { console.error(`cannot read ${file}: ${e.message}`); process.exit(2); }
  const verdict = validatePatch(text);
  process.stdout.write(JSON.stringify(verdict) + "\n");
  process.exit(verdict.ok ? 0 : 1);
}
