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
  if (p === ".." || p.startsWith("../") || p.includes("/../") || p.endsWith("/..")) return false; // traversal
  return allow.some((prefix) => p.startsWith(prefix));
}

// Unquote a git diff path. Git quotes paths with special chars as C-strings ("a\tb"); a quoted path is
// itself suspicious in an untrusted patch, so we DECODE it (to check it honestly) but the caller still
// runs it through pathAllowed. Returns the raw string with the a/ or b/ prefix stripped.
function stripPrefix(raw) {
  let s = raw;
  if (s.length >= 2 && s[0] === '"' && s[s.length - 1] === '"') {
    // C-unquote just enough to reveal traversal/control chars; unknown escapes pass through literally.
    s = s.slice(1, -1).replace(/\\([\\"ntrbfav0]|[0-7]{1,3}|x[0-9a-fA-F]{2})/g, (m, e) => {
      const map = { n: "\n", t: "\t", r: "\r", b: "\b", f: "\f", a: "\x07", v: "\v", "0": "\0", "\\": "\\", '"': '"' };
      if (e in map) return map[e];
      if (e[0] === "x") return String.fromCharCode(parseInt(e.slice(1), 16));
      return String.fromCharCode(parseInt(e, 8));
    });
  }
  if (s === "/dev/null") return null;                  // add/delete sentinel — carries no real path
  if (s.startsWith("a/") || s.startsWith("b/")) s = s.slice(2);
  return s;
}

// Parse a unified git diff into the set of touched paths + any dangerous flags. Conservative by
// construction: every path-bearing line contributes to the path set, and any mode/marker we recognise
// as dangerous is flagged. Returns { paths:Set, flags:{...}, parseError:string|null }.
export function parsePatch(text) {
  const paths = new Set();
  const flags = { symlink: false, submodule: false, exec: false, binary: false };
  let sawDiffHeader = false;
  let parseError = null;

  const add = (raw) => { const p = stripPrefix(raw); if (p !== null) paths.add(p); };
  const lines = text.split("\n");
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
    if (line.startsWith("--- ")) { add(line.slice(4)); continue; }
    if (line.startsWith("+++ ")) { add(line.slice(4)); continue; }
    if (line.startsWith("rename from ") || line.startsWith("copy from ")) { paths.add(line.replace(/^(rename|copy) from /, "")); continue; }
    if (line.startsWith("rename to ") || line.startsWith("copy to ")) { paths.add(line.replace(/^(rename|copy) to /, "")); continue; }
    // Dangerous modes. Git symlink=120000, gitlink/submodule=160000, regular exec=100755.
    if (/^(new file mode|old mode|new mode|deleted file mode) 120000$/.test(line)) flags.symlink = true;
    if (/^(new file mode|old mode|new mode|deleted file mode) 160000$/.test(line)) flags.submodule = true;
    if (/^(new file mode|new mode) 100755$/.test(line)) flags.exec = true;
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
  if (flags.symlink) reasons.push("patch creates/alters a SYMLINK (mode 120000) — refused");
  if (flags.submodule) reasons.push("patch creates/alters a SUBMODULE / gitlink (mode 160000) — refused");
  if (flags.exec) reasons.push("patch sets the EXECUTABLE bit (mode 100755) — refused");
  if (flags.binary) reasons.push("patch contains BINARY content — refused (text patches only)");

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
