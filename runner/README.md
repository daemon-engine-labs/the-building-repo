# runner/ — the sandbox runner and its egress wall

Concrete files for **Phase 1** of [`../SETUP.md`](../SETUP.md). Together they give the untrusted
path a real isolation boundary on macOS: an ephemeral Linux container with no direct internet,
reachable only to allowlisted hosts.

| File | Role |
|---|---|
| `Dockerfile` | runner image = official Actions runner + Node 20 + the three agent CLIs |
| `tinyproxy.conf` | default-deny egress proxy config |
| `egress-allowlist.txt` | the only hosts the runner may reach (anchored regexes) |
| `up-egress.sh` | create the two docker networks + start the proxy (idempotent) |
| `run-sandbox.sh` | the ephemeral re-register loop: one clean container per job |

## Bring it up (after `colima start`)

```bash
docker build -t arena-sandbox-runner -f runner/Dockerfile runner
runner/up-egress.sh
runner/run-sandbox.sh        # leave running; wrap in launchd for persistence
```

## What makes this a wall, not a fence

- **No direct route:** the runner sits on `arena-internal` (a `--internal` docker network). Its
  only way out is the proxy, which default-denies anything not in the allowlist.
- **Ephemeral + read-only:** `--ephemeral` (one job then exit) + `--rm --read-only` + tmpfs work
  dirs. A compromised job leaves nothing behind and starts each time from a clean image.
- **No secrets, no host mounts:** nothing sensitive is on this path by construction. Phase 2's
  isolation proof verifies the secrets context is empty before we ever trust it.

## Not yet verified

These files are written but **unproven** — they have not been run against a live colima/runner.
The agent-CLI package names in the `Dockerfile` and the exact tinyproxy filter behaviour are
best-known, not yet confirmed on a real runner. Phase 2 is where we prove it.
