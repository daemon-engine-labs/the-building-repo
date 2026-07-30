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
| `com.daemon-engine.arena-*.plist` | launchd supervisors (egress + auth + sandbox + privileged + autopull) — the durable replacement for nohup |
| `arena-autopull.sh` | merge→run integrity daemon — fast-forwards the deploy worktree + relaunches idle runners onto merged code |
| `install-launchd.sh` | install/reload all LaunchAgents (idempotent, bootout-first); creates the deploy worktree |

## Bring it up (after `colima start`)

```bash
docker build -t arena-sandbox-runner -f runner/Dockerfile runner
runner/install-launchd.sh    # installs the egress wall + auth + both runners + autopull (five LaunchAgents); creates the deploy worktree
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

### The agents, and why egress is one of them

There are **five** LaunchAgents: `arena-egress`, `arena-auth`, `arena-privileged`, `arena-sandbox`, and
`arena-autopull` (the merge→run daemon — see "Merge→run integrity" below). The sandbox runner has no route out
except through the egress wall (`arena-internal` network + tinyproxy proxy), and a reboot tears those
down. Nothing used to rebuild them — so after a reboot the sandbox runner would find `arena-internal`
missing, exit, and launchd would relaunch it every 10s **forever** (a thrash, not a self-heal).
`com.daemon-engine.arena-egress` closes that: `run-egress.sh` raises the wall (`up-egress.sh`) and then
`docker wait`s on the proxy, so the agent lives exactly as long as the wall and its death re-raises.
launchd is the wall's **single** supervisor — which is why `up-egress.sh` is told
`EGRESS_RESTART_POLICY=no` here (a docker restart policy would be a second, fighting supervisor).

The installer is **bootout-first**: it unloads all agents and waits for them to disappear *before*
touching any process or container, so `KeepAlive` can't resurrect a runner mid-install (the race that
made the old "just re-run it" claim untrue). Plists are repointed at the **deploy worktree** with
`PlistBuddy`, not `sed`, so a path containing regex metacharacters can't corrupt them.

**Scope of automatic merge→run (honest):** `arena-autopull` auto-relaunches only the two **ephemeral
runners** (sandbox, privileged) — they idle-cycle safely. The long-lived `arena-egress` / `arena-auth`
agents also exec from the deploy worktree (so a reinstall runs merged code), but they are NOT
auto-relaunched on drift — kickstarting the egress wall would briefly drop every sandbox job's only
route out. Their merged code activates on the next reinstall or container death. **Named residual:** a
merged fix to `run-egress.sh` / `run-auth.sh` / `tinyproxy.conf` / allowlists can sit dark until then —
run `install-launchd.sh` to force it live.

```bash
runner/install-launchd.sh                                    # install/reload (idempotent, bootout-first)
launchctl print gui/$(id -u)/com.daemon-engine.arena-egress | grep -E 'state|pid'
launchctl print gui/$(id -u)/com.daemon-engine.arena-autopull | grep -E 'state|pid'   # merge→run daemon
docker ps --filter name=egress                               # the wall's proxy should be up
gh api repos/daemon-engine-labs/the-building-repo/actions/runners -q '.runners[].name'
tail -f ~/Library/Logs/arena-{egress,privileged,sandbox,autopull}.log
# uninstall:
launchctl bootout gui/$(id -u)/com.daemon-engine.arena-{egress,auth,privileged,sandbox,autopull}
```

### Operational caveats

- **These are LaunchAgents (`gui/$UID`), not LaunchDaemons** — they need a logged-in GUI session.
  After a headless reboot with no console login, nothing starts until someone logs in. If the runner
  host must come up unattended, enable auto-login or promote these to LaunchDaemons (root, different
  security posture) as a follow-up.
- **Ctrl-C any manually-started self-loop runners before installing.** The installer's legacy reap is
  narrow on purpose (it only matches `bash`-invoked script processes, so it can't kill an editor that
  has the file open). A runner you started as a bare `./run-sandbox.sh` may survive the reap; it's
  `--ephemeral --replace`, so a stray duplicate self-resolves, but stopping it first avoids the churn.
- **Reinstall is disruptive to an in-flight job.** After bootout, the installer stops labelled runner
  containers — a job running at that moment is cut (it re-queues on GitHub). Reinstall during a quiet
  window, or expect one interrupted build.
- **Changing `tinyproxy.conf` or `egress-allowlist.txt` needs a proxy recreate.** The egress agent
  *reuses* a healthy proxy (so a supervisor relaunch never drops live jobs), which means it will not
  pick up an edited allowlist on its own. Force it: `docker rm -f egress` (the agent re-raises within
  ~10s with the new config).
- **~10s between jobs is intentional.** `ThrottleInterval=10` caps the KeepAlive respawn rate, which
  also spaces clean job-to-job relaunches by ~10s. That's the price of the thrash cap on the failure
  path; lower it in the plists if you need tighter throughput and accept faster respawn on failures.

## Merge→run integrity (deploy worktree + autopull)

launchd relaunching a *fresh process* is not the same as the fresh process running *merged* code. The
supervisor scripts exec from a git working tree, and an **idle ephemeral runner is the one state where
oneshot never cycles** — it blocks in `./run.sh` waiting for a job, so a merge to `main` never activates
until the next relaunch, which may never come. Observed live: a sandbox runner sat **8 days** on a
pre-merge script while the merged security hardening sat un-run on disk. *Merged is not running.*

Two mechanisms close the gap:

- **Deploy worktree (removes the coupling).** The supervised services exec from a dedicated worktree at
  `$HOME/.arena-deploy` (`ARENA_DEPLOY_ROOT`), **not** the dev checkout. `install-launchd.sh` creates it
  as a linked worktree detached at `origin/main` and repoints every plist's `ProgramArguments`/
  `WorkingDirectory` there. Editing or branch-switching the dev checkout can no longer change what the
  live runner executes.
- **`arena-autopull.sh` (makes activation deterministic).** A launchd `StartInterval=60` daemon: each
  tick fetches `origin/main`, and on drift fast-forwards the deploy worktree (`--ff-only`, fail-closed on
  divergence) and relaunches any **idle** runner onto the merged code. A **busy** runner is left alone —
  it self-heals for free when its one ephemeral job finishes and launchd relaunches it. Idle-vs-busy is
  read from GitHub's authoritative `busy` field, not guessed from container internals. Relaunch reaps the
  orphaned `--rm` container + stale runner registration (launchd's SIGKILL skips docker `--rm` cleanup,
  which otherwise leaves a stale runner *still online* beside the fresh one). `ARENA_AUTOPULL_DRYRUN=1`
  previews a tick without mutating anything.
- **Drift stamp (makes it visible).** `run-sandbox.sh`/`run-privileged.sh` log `running SHA X
  (origin/main Y)` at registration, and a loud `⚠ DRIFT` line when they differ — read-only, never
  fetches, fully guarded so it can't wedge the fail-open gate path.

Drift is thus bounded to ≤ ~60s after a merge, and always visible in the runner log meanwhile.

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
