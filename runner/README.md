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
| `run-sandbox.sh` | the ephemeral runner: register → run one job → exit (oneshot) or self-loop |
| `run-privileged.sh` | same, labelled `privileged` (trusted code, direct egress) |
| `com.daemon-engine.arena-*.plist` | launchd supervisors — the durable replacement for nohup |
| `install-launchd.sh` | install/reload both LaunchAgents (idempotent) |

## Bring it up (after `colima start`)

```bash
docker build -t arena-sandbox-runner -f runner/Dockerfile runner
runner/install-launchd.sh    # ensures egress, installs + starts both launchd runners
```

Manual / interactive alternative (no launchd — self-looping, Ctrl-C to stop):

```bash
runner/up-egress.sh
runner/run-sandbox.sh
```

## Durable supervision (launchd, not nohup)

The runner scripts are **oneshot** under `RUNNER_ONESHOT=1`: register one ephemeral runner, run one
job, exit. **launchd is the loop** — `KeepAlive` relaunches a fresh process (with a correct `PATH`)
for every job. This kills the failure that wedged the old nohup loop: a long-lived shell cached
bash's command→path hash, so when a colima restart *moved* the `docker` binary, every `docker run`
failed with "No such file or directory" and jobs queued forever, silently.

Why launchd fixes it structurally:

- **Fresh env per job** — each relaunch re-execs; there is no long-lived process to hold a stale
  hash. (`wait_for_docker` also runs `hash -r` and blocks on `docker info`, as belt-and-suspenders.)
- **Survives crashes** (`KeepAlive`) **and reboot** (`RunAtLoad`), and self-heals boot ordering: if
  colima or the egress wall isn't ready yet, the script exits and launchd relaunches (throttled 10s).
- **Explicit `PATH`** in the plist includes `/opt/homebrew/bin` — launchd's default `PATH` excludes
  it, which would otherwise reproduce the exact "command not found" bug this service prevents.

```bash
runner/install-launchd.sh                                    # install/reload (idempotent)
launchctl print gui/$(id -u)/com.daemon-engine.arena-privileged | grep -E 'state|pid'
gh api repos/daemon-engine-labs/the-building-repo/actions/runners -q '.runners[].name'
tail -f ~/Library/Logs/arena-privileged.log
# uninstall:
launchctl bootout gui/$(id -u)/com.daemon-engine.arena-{privileged,sandbox}
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
