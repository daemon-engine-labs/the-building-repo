#!/usr/bin/env node
// arena/heartbeat.mjs — the arena's pulse. Where run.mjs is REACTIVE (a human files an
// issue, an agent builds it), the heartbeat is GENERATIVE: on a schedule the arena looks at
// what it can do and what's undone, recombines that into work it *chose*, tempers the design,
// and files its own issue. That is the whole difference between a build-bot and something with
// an agenda.
//
// It does exactly one thing per pulse, and is allowed to do nothing:
//   1. Gather substrate — the arena's own capabilities + open backlog + the org's repos.
//   2. Anti-stack guard — if a prior self-filed issue is still open, stay silent. At most one
//      self-generated issue is ever in flight, so the pulse can never flood the build loop.
//   3. Think — run Claude headless through the recombine -> ascend -> temper prompt. The model
//      returns a strict JSON decision: file one battle-tested issue, or stay silent.
//   4. Act — file the issue (labeled arena:heartbeat), or log the reason for silence and exit 0.
//
// SECURITY POSTURE (read before changing):
//   Filing an issue is the only mutating act here, and it FAILS CLOSED — any parse error,
//   missing decision, or missing token results in NO issue, never a malformed one. The issue is
//   authored by whatever token GH_TOKEN carries. In the caged phase that is the default
//   github-actions[bot], which is NOT in allowlist.txt, so triage.yml routes its issues to the
//   inert propose path — the pulse is fully visible but cannot trigger a privileged build. Arming
//   the loop is a deliberate, separate act: add a bot identity to allowlist.txt (a gated PR to
//   main — "trust is granted by merge, never by issue") AND file with a non-default token. Never
//   arm the loop from inside this file.

import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..");

const HEARTBEAT_LABEL = "arena:heartbeat";
const ORG = process.env.ARENA_ORG || "daemon-engine-labs";
const REPO = process.env.GITHUB_REPOSITORY || "daemon-engine-labs/the-building-repo";
const DRY_RUN = process.env.HEARTBEAT_DRY_RUN === "1";

// --- small helpers ------------------------------------------------------------------------

function sh(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: "utf8", maxBuffer: 32 * 1024 * 1024, ...opts });
  if (r.error) throw new Error(`spawn ${cmd} failed: ${r.error.message}`);
  return r;
}

function ghJson(args) {
  const r = sh("gh", args);
  if (r.status !== 0) throw new Error(`gh ${args.join(" ")} failed: ${r.stderr.trim()}`);
  return JSON.parse(r.stdout || "[]");
}

function readSafe(rel) {
  try {
    return readFileSync(join(repoRoot, rel), "utf8");
  } catch {
    return "";
  }
}

function log(...m) {
  console.error("[heartbeat]", ...m);
}

// --- 1. gather substrate ------------------------------------------------------------------

function gatherSubstrate() {
  // Capabilities: what the arena knows how to do. Read from the durable docs, not guessed.
  const capabilities = {
    readme: readSafe("README.md"),
    pipeline: readSafe("PIPELINE.md"),
    agents: ["claude", "codex", "gemini", "grok"]
      .map((a) => `## ${a}\n${readSafe(`agents/${a}/persona.md`).slice(0, 1200)}`)
      .join("\n\n"),
    allowlist: readSafe("allowlist.txt"),
  };

  // Backlog: what's already open here — so the pulse doesn't re-propose the known.
  const backlog = ghJson([
    "issue", "list", "--repo", REPO, "--state", "open", "--limit", "50",
    "--json", "number,title,labels",
  ]);

  // The org's repos: the wider territory the arena can recombine across.
  let orgRepos = [];
  try {
    orgRepos = ghJson([
      "repo", "list", ORG, "--limit", "30", "--json", "name,description",
    ]);
  } catch (e) {
    log("could not list org repos (non-fatal):", e.message);
  }

  return { capabilities, backlog, orgRepos };
}

// --- 2. anti-stack guard ------------------------------------------------------------------

function priorPulseStillOpen() {
  const open = ghJson([
    "issue", "list", "--repo", REPO, "--state", "open",
    "--label", HEARTBEAT_LABEL, "--limit", "1", "--json", "number,title",
  ]);
  return open[0] || null;
}

// --- 3. think (recombine -> ascend -> temper) ---------------------------------------------

function decide(substrate) {
  const method = readSafe("arena/heartbeat.prompt.md");
  if (!method) throw new Error("arena/heartbeat.prompt.md missing — refusing to think blind");

  const taskPrompt = [
    "# The arena's current substrate",
    "",
    "## Capabilities (what the arena can already do)",
    substrate.capabilities.readme.slice(0, 3000),
    "",
    "### Pipeline",
    substrate.capabilities.pipeline.slice(0, 3000),
    "",
    "### Rival builders (personas, truncated)",
    substrate.capabilities.agents,
    "",
    "## Open backlog (do NOT re-propose these)",
    JSON.stringify(substrate.backlog.map((i) => ({ n: i.number, title: i.title })), null, 2),
    "",
    "## Org repos (the territory to recombine across)",
    JSON.stringify(substrate.orgRepos, null, 2),
    "",
    "Now run the method. Emit exactly one fenced ```json block and nothing after it.",
  ].join("\n");

  const args = [
    "-p",
    "--output-format", "text",
    "--dangerously-skip-permissions",
    "--append-system-prompt", method,
    taskPrompt,
  ];

  log("thinking… (recombine -> ascend -> temper)");
  const r = sh("claude", args, { stdio: ["ignore", "pipe", "inherit"] });
  if (r.status !== 0) throw new Error(`claude exited rc=${r.status}`);
  return parseDecision(r.stdout);
}

// Extract the LAST fenced json block (the model may narrate before committing). Fail closed:
// anything we can't parse into a well-typed decision becomes "stay silent".
function parseDecision(out) {
  const fences = [...out.matchAll(/```json\s*([\s\S]*?)```/g)];
  const raw = fences.length ? fences[fences.length - 1][1] : null;
  if (!raw) {
    log("no json fence in model output — treating as silence");
    return { file: false, reason: "model produced no parseable decision" };
  }
  let d;
  try {
    d = JSON.parse(raw);
  } catch (e) {
    log("json parse failed — treating as silence:", e.message);
    return { file: false, reason: "unparseable decision json" };
  }
  if (d.file !== true) return { file: false, reason: String(d.reason || "model chose silence") };
  const title = typeof d.issue?.title === "string" ? d.issue.title.trim() : "";
  const body = typeof d.issue?.body === "string" ? d.issue.body.trim() : "";
  if (!title || !body) {
    log("file:true but issue.title/body missing — failing closed to silence");
    return { file: false, reason: "incomplete issue payload" };
  }
  return { file: true, reason: String(d.reason || ""), issue: { title, body } };
}

// --- 4. act -------------------------------------------------------------------------------

function fileIssue(issue, reason) {
  const body = [
    issue.body,
    "",
    "---",
    "*Filed autonomously by the arena's heartbeat (`arena/heartbeat.mjs`) — a self-generated,",
    "recombine→ascend→temper agenda item, not a human request. Review before the arena builds it.*",
    reason ? `\n> pulse rationale: ${reason}` : "",
  ].join("\n");

  if (DRY_RUN) {
    log("DRY_RUN — would file issue:\n  title:", issue.title, "\n  body:\n" + body);
    return;
  }
  const r = sh("gh", [
    "issue", "create", "--repo", REPO,
    "--title", issue.title,
    "--body", body,
    "--label", HEARTBEAT_LABEL,
  ]);
  if (r.status !== 0) throw new Error(`gh issue create failed: ${r.stderr.trim()}`);
  log("filed:", r.stdout.trim());
}

// --- main ---------------------------------------------------------------------------------

function main() {
  // Ensure the label exists (idempotent; --force is a no-op if unchanged). Skipped under DRY_RUN
  // so a local test is a pure read — no mutation of the live repo.
  if (!DRY_RUN) {
    sh("gh", [
      "label", "create", HEARTBEAT_LABEL, "--repo", REPO,
      "--color", "5319E7", "--description", "Self-generated by the arena's heartbeat", "--force",
    ]);
  }

  const prior = priorPulseStillOpen();
  if (prior) {
    log(`prior pulse #${prior.number} still open — staying silent (anti-stack).`);
    return;
  }

  const substrate = gatherSubstrate();
  const decision = decide(substrate);

  if (!decision.file) {
    log("silence:", decision.reason);
    return;
  }
  fileIssue(decision.issue, decision.reason);
}

main();
