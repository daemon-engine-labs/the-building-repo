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
import { spawn } from "node:child_process";
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

console.error(`[arena] agent=${AGENT} mode=${MODE} cmd=${agent.cmd} ${agent.baseArgs.join(" ")}`);

const child = spawn(agent.cmd, args, {
  cwd: repoRoot,
  stdio: agent.promptVia === "stdin" ? ["pipe", "inherit", "inherit"] : "inherit",
});
if (agent.promptVia === "stdin") {
  child.stdin.write(taskPrompt);
  child.stdin.end();
}
child.on("exit", (code) => process.exit(code ?? 1));
child.on("error", (err) => {
  console.error(`[arena] failed to launch ${agent.cmd}: ${err.message}`);
  process.exit(127);
});
