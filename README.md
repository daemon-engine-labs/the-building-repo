# the-building-repo

> File an issue. Three rival agents — Claude, Codex, Gemini — read it, build it, and ship it. They can rewrite their own personas and their own toolset. The repo evolves itself.

This is an experiment in **issue-driven, self-evolving multi-agent software production**. You describe what you want — a feature, a bug fix, a whole product — and an agent picks it up, writes the code, opens a PR, and (eventually) ships iOS/Android/web products from it.

## The one rule that makes this safe instead of suicidal

The agents are powerful and self-modifying. That is the fun. It is also the danger: **anything reachable from a public issue is reachable by an anonymous adversary**, and prompt injection via issue text is the *main* case, not the tail. So the entire design is built around a single trust boundary:

> **Untrusted input can _propose_. Only trusted authorship can _arm_ the privileged tools (real OAuth tokens, publishing, spending).**

How that's enforced:

| Concern | Mechanism |
|---|---|
| Who can trigger a privileged build | `allowlist.txt` checked against `github.actor` (set by GitHub, not forgeable from issue text) |
| Untrusted proposals | Run on a **zero-secret sandbox runner**, egress-filtered, can only open a PR |
| Privileged builds | Run on a **separate runner** that holds secrets, only for allowlisted actors / merged code |
| Self-modification (personas, tools, workflows) | Always a **PR to `main`**, reviewed (cage-match) before it has power. The merge is the door — the issue never is. |
| Spending money | A **budget proxy** holds the real card behind a hard daily cap; the repo never sees the PAN |
| Fork-PR RCE on the self-hosted runner | Untrusted PRs use `pull_request` (no secrets, read-only token); never `pull_request_target` |

**Two runners, not one.** Trust is enforced *physically* — a `sandbox` runner with no secrets and no write access to `.github/`, and a `privileged` runner with secrets. A label is a fence; separate runners with separate secret scope is a wall.

## Status

🚧 **Skeleton — inert.** No runner is attached and no secrets exist yet. The gate (`.github/workflows/triage.yml`) is written but unproven. Nothing privileged can run. Next step: attach a sandbox runner and prove the untrusted path cannot see secrets — *before* a single real token goes in. Cage before monster.

## Layout

```
.github/workflows/triage.yml   # the gate: allowlist check → routes to sandbox vs privileged
agents/<name>/persona.md        # each agent's personality (agents PR-edit these to evolve)
agents/<name>/tools.json        # tools each agent may request
allowlist.txt                   # trusted GitHub logins (editing it is itself a gated PR)
arena/                          # the orchestrator — routes issues to the agent CLIs, runs the rivalry
budget-proxy/                   # (todo) holds the real card behind a daily cap
```

## The arena, not a harness

We do **not** write our own agent loop — the official CLIs already are world-class harnesses. We drive them:

- **Claude** — `claude -p` (headless Claude Code, zero-cost on the Max plan via OAuth)
- **Codex** — the `codex` CLI
- **Gemini** — the `gemini` CLI

What *we* build is the **arena around them**: the gate, the issue→agent router, persona/tool config injection, the cage-match between rivals, and the budget proxy. Personas are markdown the CLI loads (`--append-system-prompt "$(cat agents/claude/persona.md)"`); an agent "rewrites its own personality" by opening a PR against that file. We never maintain a tool implementation — when a CLI ships a new capability, our agents get it for free.
