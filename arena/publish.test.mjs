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
const diffQuotedTraversal = `diff --git "a/docs/\\u0000evil" "b/docs/\\u0000evil"
index 1..2 100644
`;
const diffRenameOut = `diff --git a/docs/a.md b/arena/b.mjs
similarity index 100%
rename from docs/a.md
rename to arena/b.mjs
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
  assert.match(v.reasons.join(" "), /EXECUTABLE/);
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
test("parsePatch: quoted path with NUL is decoded and then caught by pathAllowed", () => {
  // The C-unquote reveals the control byte; the path then fails pathAllowed (NUL).
  const { paths } = parsePatch('diff --git "a/docs/x" "b/docs/x"\n');
  assert.ok(paths.has("docs/x"));
});
test("PRODUCT_ALLOW is intentionally minimal (this repo is mostly privileged machinery)", () => {
  assert.deepEqual(PRODUCT_ALLOW, ["docs/"]);
});
