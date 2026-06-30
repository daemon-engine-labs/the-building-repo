# Sandbox runner image: the official GitHub Actions runner + Node + the three agent CLIs.
# Built on the host (which has normal internet); the *job's* network is what we wall off.
#
# NOTE (verify before trusting): the agent-CLI package names below are best-known as of
# 2026-06. Confirm each installs and authenticates in your runner before relying on it.
FROM ghcr.io/actions/actions-runner:latest

USER root

# Node 20 (NodeSource — apt's nodejs is too old for the CLIs).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg git \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# The three rivals. `|| true` so a transient registry hiccup doesn't break the image;
# run.mjs already refuses any agent whose CLI is missing (installed:false / launch error).
RUN npm i -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli || true

USER runner
