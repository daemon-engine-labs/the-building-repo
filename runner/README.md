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
| `run-egress.sh` | supervise the egress wall: raise it, then `docker wait` the proxy so its death re-raises |
| `run-sandbox.sh` | the ephemeral runner: register → run one job → exit (oneshot) or self-loop |
| `run-privileged.sh` | same, labelled `privileged` (trusted code, direct egress) |
| `com.daemon-engine.arena-*.plist` | launchd supervisors (egress + sandbox + privileged) — the durable replacement for nohup |
| `install-launchd.sh` | install/reload all three LaunchAgents (idempotent, bootout-first) |

## Bring it up (after `colima start`)

```bash
docker build -t arena-sandbox-runner -f runner/Dockerfile runner
runner/install-launchd.sh    # installs + starts the egress wall + both runners (three LaunchAgents)
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

### Three agents, and why egress is one of them

There are **three** LaunchAgents, not two. The sandbox runner has no route out except through the
egress wall (`arena-internal` network + tinyproxy proxy), and a reboot tears those down. Nothing used
to rebuild them — so after a reboot the sandbox runner would find `arena-internal` missing, exit, and
launchd would relaunch it every 10s **forever** (a thrash, not a self-heal). `com.daemon-engine.arena-egress`
closes that: `run-egress.sh` raises the wall (`up-egress.sh`) and then `docker wait`s on the proxy, so
the agent lives exactly as long as the wall and its death re-raises. launchd is the wall's **single**
supervisor — which is why `up-egress.sh` is told `EGRESS_RESTART_POLICY=no` here (a docker restart
policy would be a second, fighting supervisor).

The installer is **bootout-first**: it unloads all three agents and waits for them to disappear
*before* touching any process or container, so `KeepAlive` can't resurrect a runner mid-install (the
race that made the old "just re-run it" claim untrue). Plists are repointed at this checkout with
`PlistBuddy`, not `sed`, so a checkout path containing regex metacharacters can't corrupt them.

```bash
runner/install-launchd.sh                                    # install/reload (idempotent, bootout-first)
launchctl print gui/$(id -u)/com.daemon-engine.arena-egress | grep -E 'state|pid'
docker ps --filter name=egress                               # the wall's proxy should be up
gh api repos/daemon-engine-labs/the-building-repo/actions/runners -q '.runners[].name'
tail -f ~/Library/Logs/arena-{egress,privileged,sandbox}.log
# uninstall:
launchctl bootout gui/$(id -u)/com.daemon-engine.arena-{egress,privileged,sandbox}
```

## What makes this a wall, not a fence

- **No direct route:** the runner sits on `arena-internal` (a `--internal` docker network). Its
  only way out is the proxy, which default-denies anything not in the allowlist.
- **Ephemeral:** `--rm --ephemeral` (one job then exit). A compromised job leaves nothing behind and
  starts each time from a clean image. (The container is *not* `--read-only`: the Actions runner
  writes `.env`/`.path`/`_diag`/`_work` into its own home, which a read-only rootfs blocks.
  Ephemerality + network isolation + no secrets + no host mounts already bound the blast radius —
  read-only was redundant. Named tradeoff.)
- **No secrets, no host mounts:** nothing sensitive is on this path by construction. Phase 2's
  isolation proof verifies the secrets context is empty before we ever trust it.

## Verification status

- **Proven live:** the two-runner launchd supervision has run on the host (both agents up, ephemeral
  runners registering).
- **Written + locally validated, not yet re-installed live:** the egress LaunchAgent, the bootout-first
  installer, and the `PlistBuddy` path rewrite in *this* change. They pass `shellcheck`, `plutil -lint`,
  and a `PlistBuddy`-rewrite dry-run against an adversarial checkout path — but a live `install-launchd.sh`
  re-run on the runner host is the next gate before calling the three-agent topology done.
- **Best-known, unconfirmed:** the agent-CLI package names in the `Dockerfile` and the exact tinyproxy
  filter behaviour. Phase 2 proves these on a real runner.
