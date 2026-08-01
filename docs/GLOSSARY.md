# Glossary

The arena's domain vocabulary, alphabetically. Read this before the workflows if the terms below are unfamiliar.

### arena-auth

The credential-off-sandbox proxy (`runner/arena-auth/`) that hands each sandbox job a single-use, budget-capped nonce for model access instead of a real token, so untrusted builds never see a live secret.

### cage-match

The adversarial multi-model PR review (Maxwell/Kelvin/Carnot/Tesla/Wu) with a strict merge gate — every agent's own output is judged by the others before it can land.

### deploy worktree

The dedicated git worktree the launchd services exec from, decoupling running code from the dev checkout so a `git pull` in one doesn't destabilize the other mid-run.

### drift stamp

The log line a runner emits comparing its worktree SHA to `origin/main`, making merge→run drift visible instead of silently running stale code.

### gate

The triage job that routes an issue to the trusted (allowlisted author) or untrusted (propose-only) build path, based on `github.actor` against `allowlist.txt`.

### heartbeat

The scheduled pulse that keeps the arena warm and files self-generated build-request issues, authored by a non-allowlisted identity so it always routes through the propose path.

### privileged path

The trusted build: real tokens, opens a PR directly, allowlisted authors only.

### propose path

The untrusted, zero-secret sandbox build that emits a diff artifact a default-deny publisher may turn into a PR.

### spend cage

The fail-closed validator that gates any real-money spend request before the budget proxy authorizes it.
