// arena/publish.mjs tests — the default-deny patch gate. QUOTA-FREE, pure functions only.
// Run: node --test arena/publish.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { validatePatch, pathAllowed, parsePatch, PRODUCT_ALLOW } from "./publish.mjs";

// Minimal real git diffs (as `git diff` emits them) for each case.
const diffDocs = `diff --git a/docs/guide.md b/docs/guide.md
index e69de29..4b825dc 100644
--- a/docs/guide.md
+++ b/docs/guide.md
@@ -0,0 +1 @@
+hello
`;
const diffDocsNew = `diff --git a/docs/new.md b/docs/new.md
new file mode 100644
index 0000000..4b825dc
--- /dev/null
+++ b/docs/new.md
@@ -0,0 +1 @@
+new content
`;
const diffPrivileged = `diff --git a/arena/run.mjs b/arena/run.mjs
index 1111111..2222222 100644
--- a/arena/run.mjs
+++ b/arena/run.mjs
@@ -1 +1 @@
-safe
+process.env.CLAUDE_CODE_OAUTH_TOKEN
`;
const diffWorkflow = `diff --git a/.github/workflows/triage.yml b/.github/workflows/triage.yml
index 1111111..2222222 100644
--- a/.github/workflows/triage.yml
+++ b/.github/workflows/triage.yml
@@ -1 +1 @@
-x
+y
`;
const diffSymlink = `diff --git a/docs/link b/docs/link
new file mode 120000
index 0000000..1234567
--- /dev/null
+++ b/docs/link
@@ -0,0 +1 @@
+/etc/passwd
`;
const diffSubmodule = `diff --git a/docs/mod b/docs/mod
new file mode 160000
index 0000000..abcdef1
--- /dev/null
+++ b/docs/mod
@@ -0,0 +1 @@
+Subproject commit abcdef1234567890abcdef1234567890abcdef12
`;
const diffExec = `diff --git a/docs/script.sh b/docs/script.sh
old mode 100644
new mode 100755
`;
const diffBinary = `diff --git a/docs/img.png b/docs/img.png
new file mode 100644
index 0000000..1234567
Binary files /dev/null and b/docs/img.png differ
`;
const diffTraversal = `diff --git a/docs/../.github/x b/docs/../.github/x
index 1111111..2222222 100644
--- a/docs/../.github/x
+++ b/docs/../.github/x
@@ -1 +1 @@
-a
+b
`;
const diffRenameOut = `diff --git a/docs/a.md b/arena/b.mjs
similarity index 100%
rename from docs/a.md
rename to arena/b.mjs
`;
// A non-100755 executable mode (Tesla T1): a denylist of {100755} would miss 100700.
const diffExecSneaky = `diff --git a/docs/x.sh b/docs/x.sh
new file mode 100700
index 0000000..1234567
--- /dev/null
+++ b/docs/x.sh
@@ -0,0 +1 @@
+#!/bin/sh
`;
// A quoted rename that STAYS under docs/ (must be accepted once unquoted — Tesla T4).
const diffQuotedRenameIn = `diff --git a/docs/old.md b/docs/new.md
similarity index 100%
rename from "docs/old.md"
rename to "docs/new name.md"
`;
// A copy OUT to a privileged path (Tesla T4 — copy lines must be gated too).
const diffCopyOut = `diff --git a/docs/a.md b/agents/claude/persona.md
similarity index 100%
copy from docs/a.md
copy to agents/claude/persona.md
`;

// ── path allowlist primitive ────────────────────────────────────────────────────
test("pathAllowed: docs/ allowed; siblings and privileged denied", () => {
  assert.equal(pathAllowed("docs/x.md"), true);
  assert.equal(pathAllowed("docs/sub/y.md"), true);
  assert.equal(pathAllowed("docsx/x.md"), false);        // prefix boundary — not a real subpath
  assert.equal(pathAllowed("arena/run.mjs"), false);
  assert.equal(pathAllowed(".github/workflows/x.yml"), false);
  assert.equal(pathAllowed("allowlist.txt"), false);
});
test("pathAllowed: traversal / absolute / NUL rejected", () => {
  assert.equal(pathAllowed("docs/../.github/x"), false);
  assert.equal(pathAllowed("../secret"), false);
  assert.equal(pathAllowed("/etc/passwd"), false);
  assert.equal(pathAllowed("docs/a/../../x"), false);
  assert.equal(pathAllowed("docs/x\0.md"), false);
  assert.equal(pathAllowed(""), false);
});

// ── the verdict on real diffs ───────────────────────────────────────────────────
test("validatePatch: a docs-only edit is ACCEPTED", () => {
  const v = validatePatch(diffDocs);
  assert.equal(v.ok, true, v.reasons.join("; "));
  assert.deepEqual(v.paths, ["docs/guide.md"]);
});
test("validatePatch: a docs-only NEW file is ACCEPTED (/dev/null side ignored)", () => {
  const v = validatePatch(diffDocsNew);
  assert.equal(v.ok, true, v.reasons.join("; "));
  assert.deepEqual(v.paths, ["docs/new.md"]);
});
test("validatePatch: a patch touching arena/ is REJECTED (privilege escalation)", () => {
  const v = validatePatch(diffPrivileged);
  assert.equal(v.ok, false);
  assert.deepEqual(v.rejected, ["arena/run.mjs"]);
});
test("validatePatch: a patch touching .github/ is REJECTED", () => {
  const v = validatePatch(diffWorkflow);
  assert.equal(v.ok, false);
  assert.ok(v.rejected.includes(".github/workflows/triage.yml"));
});
test("validatePatch: symlink REFUSED even under docs/", () => {
  const v = validatePatch(diffSymlink);
  assert.equal(v.ok, false);
  assert.match(v.reasons.join(" "), /SYMLINK/);
});
test("validatePatch: submodule/gitlink REFUSED", () => {
  const v = validatePatch(diffSubmodule);
  assert.equal(v.ok, false);
  assert.match(v.reasons.join(" "), /SUBMODULE/);
});
test("validatePatch: executable bit REFUSED", () => {
  const v = validatePatch(diffExec);
  assert.equal(v.ok, false);
  assert.match(v.reasons.join(" "), /EXECUTABLE|100755/);
});
test("validatePatch: a NON-100755 exec mode (100700) is REFUSED (mode allowlist, not denylist)", () => {
  const v = validatePatch(diffExecSneaky);
  assert.equal(v.ok, false);
  assert.match(v.reasons.join(" "), /100700|only 100644/);
});
test("validatePatch: a QUOTED rename staying under docs/ is ACCEPTED (unquote applies to renames)", () => {
  const v = validatePatch(diffQuotedRenameIn);
  assert.equal(v.ok, true, v.reasons.join("; "));
});
test("validatePatch: a copy OUT to a privileged path is REJECTED", () => {
  const v = validatePatch(diffCopyOut);
  assert.equal(v.ok, false);
  assert.ok(v.rejected.includes("agents/claude/persona.md"), `rejected=${v.rejected}`);
});
test("pathAllowed: backslash / double-slash / dot-segment shapes refused", () => {
  assert.equal(pathAllowed("docs\\evil"), false);
  assert.equal(pathAllowed("docs//x"), false);
  assert.equal(pathAllowed("docs/./x"), false);
  assert.equal(pathAllowed("./docs/x"), false);
});
test("validatePatch: binary content REFUSED", () => {
  const v = validatePatch(diffBinary);
  assert.equal(v.ok, false);
  assert.match(v.reasons.join(" "), /BINARY/);
});
test("validatePatch: path traversal that escapes docs/ is REJECTED", () => {
  const v = validatePatch(diffTraversal);
  assert.equal(v.ok, false);
  assert.ok(v.rejected.some((p) => p.includes("..")));
});
test("validatePatch: a rename OUT of docs/ into arena/ is REJECTED", () => {
  const v = validatePatch(diffRenameOut);
  assert.equal(v.ok, false);
  assert.ok(v.rejected.includes("arena/b.mjs"), `rejected=${v.rejected}`);
});
test("validatePatch: empty patch → not ok, flagged empty (nothing to publish)", () => {
  const v = validatePatch("");
  assert.equal(v.ok, false);
  assert.equal(v.empty, true);
});
test("validatePatch: non-empty garbage with no diff header → REJECTED (fail-closed)", () => {
  const v = validatePatch("i am not a patch, just prose the agent emitted\n");
  assert.equal(v.ok, false);
  assert.match(v.reasons.join(" "), /unparseable|no .diff --git/);
});
test("validatePatch: oversized patch → REJECTED", () => {
  const big = diffDocs + "+" + "x".repeat(400_000) + "\n";
  const v = validatePatch(big);
  assert.equal(v.ok, false);
  assert.match(v.reasons.join(" "), /bytes/);
});
test("validatePatch: a quoted path with an actual NUL (\\000) is decoded and REJECTED", () => {
  // git C-quotes a NUL as \000; unquote reveals it, pathAllowed then rejects (contains \0).
  const v = validatePatch('diff --git "a/docs/x\\000y" "b/docs/x\\000y"\nindex 1..2 100644\n');
  assert.equal(v.ok, false);
  assert.ok(v.rejected.some((p) => p.includes("\0")), `rejected=${JSON.stringify(v.rejected)}`);
});
test("validatePatch: a non-100644 mode on the INDEX line (unchanged-mode exec file) is REFUSED", () => {
  // Content edit of an already-exec file emits `index …..… 100755` with NO new/old mode line.
  const v = validatePatch(
    "diff --git a/docs/x b/docs/x\nindex 1111111..2222222 100755\n--- a/docs/x\n+++ b/docs/x\n@@ -1 +1 @@\n-a\n+b\n"
  );
  assert.equal(v.ok, false);
  assert.match(v.reasons.join(" "), /100755|only 100644/);
});
test("validatePatch: a normal docs edit (index …100644) is still ACCEPTED", () => {
  const v = validatePatch(
    "diff --git a/docs/x b/docs/x\nindex 1111111..2222222 100644\n--- a/docs/x\n+++ b/docs/x\n@@ -1 +1 @@\n-a\n+b\n"
  );
  assert.equal(v.ok, true, v.reasons.join("; "));
});
test("validatePatch: a docs patch that SHOWS a diff example is NOT falsely rejected", () => {
  // The added content includes a line that renders as `+++ b/arena/x` (a diff example inside a doc).
  // Paths come from `diff --git` only, so this stays a docs-only, ACCEPTED patch.
  const v = validatePatch(
    "diff --git a/docs/patch-guide.md b/docs/patch-guide.md\n" +
    "index 1111111..2222222 100644\n" +
    "--- a/docs/patch-guide.md\n" +
    "+++ b/docs/patch-guide.md\n" +
    "@@ -1,1 +1,4 @@\n" +
    " example:\n" +
    "+--- a/arena/run.mjs\n" +
    "+++ b/arena/run.mjs\n" +
    "+@@ -1 +1 @@\n"
  );
  assert.equal(v.ok, true, `should accept; got: ${v.reasons.join("; ")}`);
  assert.deepEqual(v.paths, ["docs/patch-guide.md"]);
});
test("validatePatch: CRLF line endings do NOT smuggle a symlink past the mode check", () => {
  // A hostile CRLF patch: without \r-normalisation the $-anchored mode regex misses "120000\r".
  const crlf = diffSymlink.replace(/\n/g, "\r\n");
  const v = validatePatch(crlf);
  assert.equal(v.ok, false);
  assert.match(v.reasons.join(" "), /SYMLINK/);
});
test("PRODUCT_ALLOW is intentionally minimal (this repo is mostly privileged machinery)", () => {
  assert.deepEqual(PRODUCT_ALLOW, ["docs/"]);
});
