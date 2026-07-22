#!/usr/bin/env node
// arena/run.mjs — route a GitHub issue to a rival agent CLI and let it build.
//
// We do NOT implement an agent loop. The official CLIs (claude/codex/gemini) already are
// world-class harnesses with tool use, file editing and sandboxing. The arena's only job is:
//   1. pick the agent
//   2. assemble the prompt from the issue + the agent's persona
//   3. exec the CLI in the working tree
// The surrounding workflow commits whatever the agent changed and opens a PR.
//
// Usage:
//   AGENT=claude ISSUE_TITLE="..." ISSUE_BODY="..." MODE=propose node arena/run.mjs
//
// MODE is informational here — the *real* isolation is physical (which runner, which secrets),
// enforced by the workflow, not by this script. Never rely on a flag in this file for security.

import { readFileSync } from "node:fs";
import { spawn, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..");

const AGENT = process.env.AGENT || "claude";
const MODE = process.env.MODE || "propose";
const ISSUE_TITLE = process.env.ISSUE_TITLE || "";
const ISSUE_BODY = process.env.ISSUE_BODY || "";

const config = JSON.parse(readFileSync(join(here, "agents.json"), "utf8"));
const agent = config.agents[AGENT];
if (!agent) {
  console.error(`Unknown agent "${AGENT}". Known: ${Object.keys(config.agents).join(", ")}`);
  process.exit(2);
}
if (!agent.installed) {
  console.error(
    `Agent "${AGENT}" is not yet wired (installed:false in agents.json). ${agent.note || ""}`
  );
  process.exit(3);
}

let persona = "";
try {
  persona = readFileSync(join(repoRoot, "agents", AGENT, "persona.md"), "utf8");
} catch {
  console.error(`No persona.md for "${AGENT}"; proceeding with empty persona.`);
}

// The task the agent sees. Persona is folded in here when the CLI has no system-prompt flag.
const taskPrompt = [
  agent.personaArg ? "" : persona, // fold persona into prompt when no dedicated flag
  `# Issue: ${ISSUE_TITLE}`,
  "",
  ISSUE_BODY,
  "",
  "Implement this in the current working tree. Make real, working changes. Then stop —",
  "the arena will commit your work and open a PR.",
].filter(Boolean).join("\n");

const args = [...agent.baseArgs];
if (agent.personaArg && persona) args.push(agent.personaArg, persona);
if (agent.promptVia === "positional") args.push(taskPrompt);

// Bounded retry for transient stream drops. The egress path (especially tinyproxy on the sandbox
// runner) occasionally drops a long streaming response mid-flight — the CLI exits non-zero having
// written nothing. That is a *when*, not an *if*, so we re-run. We retry ONLY on that exact
// signature: the agent failed AND left the tree unchanged. If it produced changes we must not
// clobber partial work by retrying; a clean exit needs no retry.
const MAX_ATTEMPTS = Math.max(1, parseInt(process.env.ARENA_MAX_ATTEMPTS || "3", 10));
const BACKOFF_MS = Math.max(0, parseInt(process.env.ARENA_BACKOFF_MS || "2000", 10));

function treeHasChanges() {
  try {
    return execFileSync("git", ["status", "--porcelain"], { cwd: repoRoot }).toString().trim().length > 0;
  } catch (err) {
    // Can't tell → fail safe: assume there ARE changes so we never retry over real work.
    console.error(`[arena] could not check git status (${err.message}) — assuming changes, not retrying.`);
    return true;
  }
}

function runAgentOnce() {
  return new Promise((resolve) => {
    const child = spawn(agent.cmd, args, {
      cwd: repoRoot,
      stdio: agent.promptVia === "stdin" ? ["pipe", "inherit", "inherit"] : "inherit",
    });
    if (agent.promptVia === "stdin") {
      child.stdin.write(taskPrompt);
      child.stdin.end();
    }
    child.on("exit", (code) => resolve(code ?? 1));
    child.on("error", (err) => {
      console.error(`[arena] failed to launch ${agent.cmd}: ${err.message}`);
      resolve(127);
    });
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
  console.error(
    `[arena] agent=${AGENT} mode=${MODE} cmd=${agent.cmd} ${agent.baseArgs.join(" ")} ` +
      `(attempt ${attempt}/${MAX_ATTEMPTS})`
  );
  const code = await runAgentOnce();
  if (code === 0) process.exit(0);

  // Non-zero exit. If the agent left changes, retrying risks clobbering real work — surface them.
  if (treeHasChanges()) {
    console.error(`[arena] ${AGENT} exited ${code} but produced changes — keeping them, not retrying.`);
    process.exit(code);
  }

  // Failed with a clean tree — the transient-drop signature. Retry with linear backoff.
  if (attempt < MAX_ATTEMPTS) {
    const backoffMs = BACKOFF_MS * attempt; // linear: 1×, 2×, … (ARENA_BACKOFF_MS, default 2000)
    console.error(
      `[arena] ${AGENT} exited ${code} with no changes (likely a stream drop) — retrying in ${backoffMs / 1000}s…`
    );
    await sleep(backoffMs);
    continue;
  }
  console.error(`[arena] ${AGENT} failed ${MAX_ATTEMPTS}× with no changes — giving up.`);
  process.exit(code);
}
