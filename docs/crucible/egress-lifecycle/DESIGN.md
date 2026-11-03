# DESIGN — Egress wall lifecycle: make "down, or wrong, and nobody knows" unreachable

> **Status (2026-11-03): ROUND 2 struck (RECAST, 4/4) and folded once — see "ROUND 2 FOLD" at the end, which amends the RECAST. UN-TEMPERED for build until a round-3 strike.** Round-2 brief, kept for the record: **ROUND 2 — re-strike of the RECAST.** The first candidate below (a
> long-lived wall + reconcile + watcher) was struck by four families in run `dt-egress45` (RECAST;
> see `TEMPER.md`). **The candidate under strike now is ONLY the "RECAST — the proxy is a sidecar of
> the sandbox runner" section at the end, plus the measurements it cites (M1–M11).** Everything
> above that section is the round-1 candidate, kept as history and as the fallback if the sidecar
> fails. Strike the sidecar; don't re-strike the retired long-lived design. M11 (added for this
> round) replaces the recast's key *claim* with a *measurement*.

Issue: #45 (https://github.com/daemon-engine-labs/the-building-repo/issues/45). Origin: the two-round
cage-match on #44 (https://github.com/daemon-engine-labs/the-building-repo/pull/44), whose round-2
findings across four model families were one class. Related: #33 (probe + watchdog), #46 (installer),
#47 (`arena-auth` parity), #48 (tinyproxy CVEs).

## Producer first

**The bad outcome.** The sandbox's only route to the internet is the egress proxy. The harm is: *the
route is down, or it is the wrong route, and nobody finds out*. It happened. 31,136 proxy deaths over
four months were recorded as `139` lines in a log nobody read, and they were found by accident from a
disk alert.

**The triggers are external and stay external.** Segfaults under emulation, a hostile request that
wedges the parser (CVE-2026-3945), a full disk, a colima flap. None of these can be prevented from
inside the arena.

**The producers are ours.** Each one turns a trigger into the silent harm:

| # | Producer (our code) | What it produces |
|---|---|---|
| P1 | "Healthy" is defined by **docker metadata**: `State.Running`, network membership, and `docker wait`'s exit. None of these observes the proxy *serving*. | a dead or wedged proxy reported as up |
| P2 | The desired state is **never written down**. The reuse test re-derives "is this the wall I want" from a hand-picked subset (running, restart policy, image ID, `arena-internal` membership). | silent drift in everything outside the subset |
| P3 | Replacement is **destroy-then-create on a singleton name** | a failed create leaves no proxy at all |
| P4 | launchd converts every death into a relaunch **with no memory and no outward signal** | "nobody knows" |
| P5 | Existence of a network named `arena-internal` is taken as proof that it is `--internal` | a wall with a hole in it, reported as a wall |

**The restructure.** The wall gets one written-down desired state, a health signal that observes
*serving and filtering*, a replace path that never leaves zero proxies, and a reader outside the box.
Concretely:

1. **Health is observed, not inferred** (deletes P1). The image gets a `HEALTHCHECK`: a CONNECT to a
   deny canary (`wall-canary.invalid:443`) against `127.0.0.1:8888` must return ` 403 `. Everything
   that previously asked "is it Running / is it on the network" asks "is it `healthy`" instead: the
   reuse test, the postcondition, the supervisor's wait, and the sandbox's pre-mint gate.
2. **One spec, stamped on the container** (deletes P2). The run arguments live in exactly one bash
   array. The spec is `S = sha256(image ID, the run-args array, sha256(tinyproxy.conf),
   sha256(egress-allowlist.txt))`, stamped as the label `arena.egress.spec=S` on every container the
   script creates. Reuse requires `label == S` **and** `healthy`.
3. **Create beside, then swap** (deletes P3). The successor `egress-<S:12>` is created with
   `--network arena-egress --network name=arena-internal,alias=egress`, waits for `healthy`, and only
   then are the old containers removed and the successor renamed to `egress`. A successor that never
   goes healthy is removed, and the old proxy keeps serving.
4. **The counter lives where the OS and the counterparty already keep it** (deletes P4 without a
   state file). launchd already counts relaunches (`launchctl print … runs`). A watcher outside the
   proxy reads that count plus health and reachability, and writes the result to GitHub, where Nick
   reads on his phone. The previous `runs` value is read back *from GitHub*, so no local state file is
   parsed under `set -e`.
5. **The property the wall depends on is asserted** (P5 is a residual check; see below for why it
   cannot be deleted).

## Measured facts this design stands on (2026-10-31, Docker 29.5.2 / API 1.54, colima, throwaway `egtest-*` only)

| # | Measurement | Result | Consequence |
|---|---|---|---|
| M1 | A **stopped** container keeps its `.NetworkSettings.Networks` entry (Noether, #44 r2) | `running=false`, membership test → yes | network membership can never be a liveness signal |
| M2 | busybox `nc` exists in the proxy image; a CONNECT probe against 127.0.0.1:8888 | deny → `403 Filtered`, allow → `200 Connection established` | a self-contained probe needs no extra image and no TLS |
| M3 | Deny canary with the proxy on an internal-only network (no internet, no DNS) | `wall-canary.invalid` → `403`, `example.org` → `403`, allowed `api.github.com` → `500 Unable to connect` | the 403 is the **filter** deciding on the host string. The probe is upstream-independent. |
| M4 | `HEALTHCHECK` with the deny canary under `--read-only --cap-drop ALL --security-opt no-new-privileges`, `USER tinyproxy` | `healthy`; after `SIGSTOP` (a wedge) → `running=true`, `health=unhealthy` | detects a wedged-but-Running proxy, which nothing does today |
| M5 | `docker wait` on an unhealthy-but-Running container | does **not** return | today's supervisor primitive is blind to a wedge (#45 class member 4) |
| M6 | `docker events` | emits `health_status: healthy` / `health_status: unhealthy` | health transitions are observable without polling |
| M7 | `--network-alias X` on a multi-`--network` create | alias lands on the **first** network only (`egtest-fe=[X] egtest-fi=[]`) | the obvious syntax silently breaks the swap; must use the per-network form |
| M8 | `--network name=<internal>,alias=egress` per-network form | alias on the internal network. During overlap DNS returns **both** IPs; after removing the old container the name resolves to the new one, and the CONNECT probe through the name works with no gap; still works after `docker rename` | create-beside is viable, with zero DNS gap |
| M9 | Heartbeat workflow `runs-on` | `ubuntu-latest` (GitHub-hosted, off the box) | it can serve as an independent dead-man's switch for the watcher |

## Proposed shape

**A. `runner/egress/Dockerfile` gets a HEALTHCHECK.**
```
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD printf 'CONNECT wall-canary.invalid:443 HTTP/1.0\r\n\r\n' | nc -w 2 127.0.0.1 8888 | grep -q ' 403 '
```
`.invalid` is reserved (RFC 2606) and can never be a real host. The check proves two things: the proxy
**answers**, and **default-deny is in force**. If anyone ever widens the allowlist to admit the canary
(`.*`, say), the check stops returning 403, the wall reads **unhealthy**, and the change is loud. The
allow path is deliberately *not* in the HEALTHCHECK: it depends on GitHub being up, and recreating the
proxy does not fix a GitHub outage (rejected alternative R-d).

**B. `runner/up-egress.sh` becomes a reconcile, not a reuse heuristic.**
1. Build the image if its hash tag is missing (unchanged). Assert `arena-internal` has
   `Internal == true`, or **refuse** (P5).
2. Compute `S` from the single run-args array plus the image ID and the two config hashes.
3. Look for a container labelled `arena.wall=egress` with `arena.egress.spec == S` whose health is
   `healthy`. If it exists and is named `egress`, do nothing. If it exists under another name (a
   rename that failed last time), rename it to `egress`. Done.
4. Otherwise create `egress-<S:12>` beside whatever is running (both networks, per-network alias
   `egress` on `arena-internal`, both labels), and wait up to N seconds for `healthy`.
   - If it never gets there: **remove the successor, leave the old proxy alone, exit non-zero**. The
     failure is loud (the watcher reports it) and the wall stays up on the old spec.
   - If it does: remove every other `arena.wall=egress` container, plus the legacy unlabelled
     `egress` (`rm -fv`). Then `docker rename` the successor to `egress`.
5. Postcondition: the container named `egress` is `healthy` and carries spec `S`. Membership is no
   longer a postcondition: creating on both networks is atomic, and M1 makes membership unusable as
   liveness anyway.

**C. `runner/run-egress.sh` waits on health, not exit.** `exec docker wait egress` becomes a stateless
poll whose only loop variable is the container's own state:
```
while s=$(docker inspect -f '{{.State.Status}}/{{.State.Health.Status}}' egress 2>/dev/null); do
  case "$s" in running/healthy|running/starting) sleep 10 ;; *) break ;; esac
done
exit 1   # dead, unhealthy, or gone → launchd relaunches → up-egress reconciles (create-beside)
```
Every command is in a condition context, so `set -e` cannot abort mid-loop, and a failed `inspect`
(container gone, daemon down) ends the loop. No persisted state. This is the shape that the two
FAIL_STATE `set -e` regressions argue for. Polling was chosen over a `docker events` stream (M6
proves events work) because bash stream handling (pipeline subshells, SIGPIPE, a stream that ends
with the daemon) is the fragile zone (R-f).

**D. `runner/run-sandbox.sh`'s pre-mint gate asks the same question.** The three-part predicate
(network exists, Running, on `arena-internal`) becomes: `arena-internal` is `Internal=true`, and
`egress` is `healthy`. One definition of "the wall is up", used by everything.

**E. A watcher outside the proxy: `com.daemon-engine.arena-wallwatch`** (a LaunchAgent with
`StartInterval 300`; one tick = one stateless run, using `arena-autopull.sh`'s `bounded` timeout
idiom). Each tick:
- reads `runs` and `last exit code` from `launchctl print gui/$UID/com.daemon-engine.arena-egress`,
  plus `egress` health and spec label;
- probes **reachability** from `arena-internal` (allow canary `api.github.com` → `200`, deny canary →
  `403`), reported but never acted on;
- computes the deploy tree's `S` and compares it with the running label, so **spec drift** (merged but
  not live) is visible;
- **rewrites the body** of one pinned issue, "Arena wall status", with the current state and the
  `runs` value, and **posts a comment only on a transition** (healthy ↔ degraded, or a relaunch rate
  above a threshold). It decides that by reading the previous body *from GitHub*.

So the death counter has no local file: launchd keeps the count and GitHub keeps the last value seen.
The counterparty writes the ACK. Comments notify Nick's phone. Editing an issue or commenting on one
does not fire `triage.yml`, which only triggers on `issues: [opened, labeled]`.

**F. Dead-man's switch for the watcher.** The daily `heartbeat.yml` (GitHub-hosted, M9) checks the
pinned issue's `updated_at` and comments if it is older than an hour. A silent watcher is then
reported from off the box. Without this, the watcher's own death would look exactly like "all quiet",
the same success-equals-absence defect this design exists to remove.

## The six class members (#45) plus the two measured facts

| Class member | Producer | This design | Deleted or residual |
|---|---|---|---|
| 1. Silent relaunch loop | P4 | The watcher reports the relaunch rate (launchd `runs`) and posts on transitions; the heartbeat checks the watcher | **Deleted** ("silent"). The loop itself stays: relaunching is the correct response, and egress relaunches are cheap (no token mint, no external API), so no backoff is added (R-c). |
| 2. Postcondition passes a dead proxy | P1 | The postcondition is `healthy`, from the HEALTHCHECK (M4) | **Deleted.** M1 retires membership as liveness. |
| 3. Remove before create | P3 | Create-beside, health-gated, then remove and rename (M8) | **Deleted.** A failed successor never touches the serving proxy. |
| 4. Wedged-but-Running reused forever | P1 | Reuse requires `healthy`; the supervisor's poll breaks on `unhealthy` (M4, M5) | **Deleted** as a *silent forever* state. Residual: CVE-2026-3945 can re-wedge on every hostile job, which means per-job recreate churn (availability, fail-closed), tracked in #48. |
| 5. Reuse blind to run flags and mounts | P2 | The spec label covers image ID + the run-args array + config hashes | **Deleted.** Any edit changes `S`, and the next reconcile swaps. Activation timing is the separate "merged is not live" question; spec drift is now *reported* by the watcher. |
| 6. `arena-internal` existence taken as `--internal` | P5 | Assert `Internal == true` in up-egress (refuse to raise) and in the sandbox gate (refuse to mint) | **Residual check, with reason.** A docker network is a shared object that any docker-socket holder can create or replace, and the socket is root-equivalent. No arena design can stop a root-equivalent actor from creating a same-named open network, so assert-and-refuse is the honest residual. Deleting the producer would mean the arena owning the docker daemon, which it doesn't. |
| Noether: a stopped container keeps its network entry (M1) | P1 | Membership is no longer read as liveness anywhere | Fact absorbed; no code relies on it |
| Tesla: `--internal` is assumed, not asserted | P5 | Same as member 6 | Residual check |

## What this is not

- **Not a FAIL_STATE extension.** #33 asked for the FAIL_STATE fork to be decided before probing. This
  design adds **no** persisted counter for egress. Its counter is launchd's `runs` read against
  GitHub's copy. That pattern is also offered as the stateless answer to the runners' FAIL_STATE fork,
  but adopting it there is a separate change.
- **Not a shared helper yet.** `arena-auth` (#47) has the same reconcile shape, and B could become one
  `reconcile-container` function. Caveat: `arena-auth` takes `-e REAL_OAUTH_TOKEN`, so its spec must
  hash the **names** of secret env vars, never their values, and a token rotation would then not
  trigger a swap. Recorded, not built.
- **Not the installer.** `install-launchd.sh`'s teardown-before-prepare ordering is #46. With B in
  place, though, the installer no longer needs to force-drop `egress` at all: a changed spec swaps by
  itself on the next reconcile.

## Build order (each step independently useful, each tested on the `egtest-*` suite)

1. **HEALTHCHECK** in `egress/Dockerfile`. `docker ps` shows health from day one, and the deny-canary
   self-test proves default-deny is in force.
2. **Health replaces Running** in up-egress's reuse test and postcondition, and in run-sandbox's gate,
   plus the `Internal == true` assertion in both. Runtime-prove each refusal path (a stopped proxy, an
   unhealthy proxy, a non-internal network) before calling it done.
3. **Supervisor poll** in run-egress.sh. Runtime-prove: wedge (SIGSTOP) → exit → relaunch → recreate;
   container removed → exit; daemon down → exit.
4. **Spec label + single run-args array.**
5. **Create-beside swap** with the per-network alias + rename + reconcile-by-label. Runtime-prove a
   failed successor (e.g. an unreadable conf) leaves the old proxy serving.
6. **wallwatch + pinned issue + heartbeat dead-man's switch.**

## Claims to falsify (hand these to the adversary)

1. The deny-canary HEALTHCHECK can't false-negative under legitimate load. Tinyproxy's `MaxClients`
   (default 100) is shared by the probe; the sandbox runs one job at a time.
2. The poll loop in C can't abort silently under `set -e`. Every command sits in a condition context.
3. The per-network alias (M8) behaves the same after a colima restart, and with the legacy unlabelled
   `egress` as the *old* container during the first migration.
4. `docker rename` of the successor while a client holds a connection to it does not drop that
   connection.
5. Writing an issue body and commenting from the box's `gh` identity can't fire any workflow
   (`triage.yml`: `issues: [opened, labeled]` only; `issues: edited` and `issue_comment` are not
   listed).
6. The spec covers everything that defines the wall. What about the tinyproxy binary inside an image
   rebuilt under the same Dockerfile? That is covered: the image ID is in `S`.

## Rejected alternatives

- **R-a: docker `--restart on-failure`, no launchd.** Docker never restarts on *unhealthy*, and two
  supervisors on one container fight (already decided in PR #7).
- **R-b: an autoheal sidecar with the docker socket mounted.** That's root on the host, inside a
  container. Cage-before-monster says no.
- **R-c: FAIL_STATE-style backoff for egress.** Egress relaunches cost nothing external. Backoff would
  only delay recovery, and it would re-enter the `set -e` state-file class that regressed twice.
  Visibility is what was missing, not rate-limiting.
- **R-d: the allow path in the HEALTHCHECK.** It couples recreate decisions to GitHub's availability:
  an upstream outage would cause recreate flapping. The allow path is the watcher's job, report-only.
- **R-e: replace tinyproxy.** Out of scope (#48). This lifecycle is proxy-agnostic; any proxy with a
  deny path can feed the canary.
- **R-f: `docker events` as the wait primitive.** It works (M6), but bash stream handling is the
  fragile zone, and a 10 s poll is easy to verify.
- **R-g: `--network-alias` (the common syntax) for the swap.** M7: it lands on the first network only.
  It *looks* right and silently breaks the swap. The per-network form is required.

## Open variables (no silent TODOs)

- The canary hostname (`wall-canary.invalid` proposed) and the HEALTHCHECK interval/retries (10 s × 3
  proposed: about 30 s to unhealthy).
- Should a reported **spec drift** also be **activated** automatically? The option is for autopull or
  wallwatch to trigger the swap, guarded by GitHub's runner `busy` field like the runners are. Report
  only is the safe first step.
- Where the pinned status issue lives (this repo is public, and status text is world-readable).
- wallwatch's relaunch-rate threshold for "degraded" (e.g. more than 3 `runs` in a 5-minute tick).

## TEMPER RESULTS (round 1 — run `dt-egress45`, 4-family strike, 2026-10-31)

**Verdict: RECAST.** Maxwell DISSOLVE · Carnot RECAST · Noether RECAST · Tesla RECAST (Wu disabled).
Full strikes and the deduped flaw list are in `TEMPER.md`. In one line each:

- **Carnot:** the successor is exposed before validation, the swap drops live connections, a label is
  provenance rather than state, a failed swap keeps a revoked policy, and the heartbeat can
  acknowledge itself.
- **Noether:** launchd `runs` **resets on reboot or reload** (a rebooted crash loop reads as
  improvement), the reconcile is unserialized (zero-proxy race), a deny-only gate can't prove the
  route is *right*, and notification isn't exactly-once.
- **Tesla:** edge-only notification plus an `updated_at` dead-man's switch is "the unread log moved
  onto a GitHub issue"; a daily checker can't enforce an hour; alias-at-birth hands jobs an
  unverified route; probe starvation can demolish a serving proxy; the network ID and `Internal`
  belong in `S`.
- **Maxwell (author):** wrong option-frame. The proxy's only client is an ephemeral runner, so tie the
  proxy's lifetime to it.

Seven of the eight deduped flaws are properties of the **long-lived** frame (a successor, a swap, a
reconcile, a box-side watcher). That is why the recast below changes the frame instead of adding
the guards the adversaries' fold-backs describe. Their fold-backs remain the fallback if the
sidecar fails a measurement.

## RECAST — the proxy is a sidecar of the sandbox runner (current candidate · UN-TEMPERED, not yet struck)

**The producer of the producers.** The proxy is a long-lived singleton with its own supervisor,
serving a client (the sandbox runner) that is created and destroyed around **one job**. Staleness,
replace-in-place hazards, drift detection, and the watcher all exist because those two lifecycles
are decoupled. Couple them.

**Shape.**
1. `run-sandbox.sh`'s `run_job` raises the wall it needs before it mints a registration token:
   - assert `arena-internal` has `Internal == true`, else infra-not-ready (exit, no backoff, no mint);
   - `docker rm -fv egress`, removing any orphan from a SIGKILLed predecessor. Safe *by construction*:
     the proxy's only client is this runner, which doesn't exist yet;
   - create the proxy on both networks at once, from the deploy tree's current image and config;
   - wait for the HEALTHCHECK (deny canary, `--start-interval=1s`) to report `healthy`, bounded,
     else infra-not-ready.
2. The runner then registers and long-polls GitHub **through** the proxy. A successful registration
   is the end-to-end allow-path check. The deny canary proved the filter, and registration proves
   the route.
3. The pair lives and dies together. When the runner container exits (job done, or killed),
   `run_job` removes the proxy. If the proxy *process* exits first, a scoped `docker wait egress`
   started by `run_job` removes the runner container, so `run_job` returns and launchd relaunches
   a fresh pair. Health is **never** a demolition trigger: it gates creation only (Tesla's
   probe-starvation flaw).
4. **Deleted outright:** the `com.daemon-engine.arena-egress` LaunchAgent, `run-egress.sh`,
   up-egress's reuse heuristic, the spec label, create-beside, alias/rename, and the box-side
   watcher. `up-egress.sh` shrinks to a function `run_job` calls. `install-launchd.sh` drops the
   egress agent and its 30 s readiness wait. `up-auth.sh` already creates the networks if missing.
5. **Visibility comes from the counterparty, read from off the box.** A GitHub-hosted scheduled
   check reads the repo's runner list via the API. "No online `sandbox` runner for longer than T"
   pages on **every** run where it holds (no edge detection, no stored baseline), through a
   non-public channel. The runner's online state is written by GitHub from a long-poll that crosses
   the wall, so this check sees the wall, not a box-side writer. Schedule period ≤ the stated bound.

**Measured for the recast (M10, throwaway `egtest-*`):** a fresh proxy reports `healthy` after
**~10 s** with `--interval=10s`, and **~2 s** with `--start-interval=1s` (Docker ≥ 25). That's the
per-job registration-gate cost.

**M11 — the recast's key claim, measured (2026-11-03, round 2).** Setup: a real ephemeral Actions
runner (`arena-sandbox-runner` image, runner 2.338.2) registered with this repo under a unique
label and `--no-default-labels` (so nothing could dispatch to it). It sat on an `--internal`
throwaway network whose only route out was a throwaway tinyproxy sidecar built from
`runner/egress/Dockerfile`. Its status was read from GitHub's runner API every 10 s, so every time
below is an upper bound with 10 s granularity. Afterwards it was de-registered (GET → 404) and all
`egtest-probe-*` artifacts were removed.

| # | Event | Result |
|---|---|---|
| M11a | Registration with the proxy as the only route | **online in 18 s**. Registration works entirely through the wall. |
| M11b | 240 s idle | **27 new CONNECTs** through the proxy (`broker.actions.githubusercontent.com`, `pipelines…actions.githubusercontent.com`, `api.github.com`, `github.com`, `release-assets…`). The idle long-poll crosses the wall continuously. Measured over minutes, not the hours claim 1 asked for. |
| M11c | Proxy **SIGKILL**ed while idle | GitHub shows the runner **offline in ≤ 33 s** |
| M11d | …the runner process | **does not exit.** It retries the broker with backoff (`Socket Error: TryAgain`, "4 attempts left"), and the container is still `running` at +33 s and through the next phase. So the runner will never end the pair by itself; something else has to. |
| M11e | The same-named proxy is **restarted** | the *old* runner is **back online in ≤ 32 s by itself**. A recreated proxy silently heals the old runner. |
| M11f | Proxy **wedged** (`docker pause`, a freezer like SIGSTOP) while idle | GitHub shows the runner **offline in ≤ 64 s**. On unpause it's online again at the first poll. |
| M11g | Proxy **wedged and left wedged** (`docker pause`, 25 min), measured during the round-2 strike | GitHub offline at **+78 s**; the runner container is **still running at +1506 s**, with 100 retry lines and no give-up. **The runner never ends a wedged pair by itself.** |
| — | Not measured | idle behaviour over *hours* (M11b covered 240 s) |

**What M11 changes in the recast.**
- Claims 1 and 2 hold at the minutes scale. **GitHub's runner status really does see the wall**,
  both its death (≤ 33 s) and a wedge (≤ 64 s), so the off-box check reads a signal that crosses
  the proxy. Detection is bounded by the check period, plus up to ~1 min.
- M11d makes shape step 3's `docker wait <proxy>` → remove-the-runner **load-bearing**, not
  optional. Without it, a dead proxy leaves a runner retrying forever, and the pair never ends.
- M11e cuts both ways. It is why nothing may recreate the proxy mid-life (a silent heal would
  erase the offline blip that the off-box check depends on). And `rm -fv egress` at `run_job`
  start must only ever happen with no runner of this kind alive, or a same-named successor would
  "heal" an orphan. The single-runner-per-host assumption carries that.
- M11f: **a wedge while idle is visible at GitHub (≤ 64 s) but nothing ends the pair.** `docker wait`
  doesn't return on a paused proxy (M5), the runner keeps retrying (M11d), and health is deliberately
  not a demolition trigger. So an idle wedge pages and stays wedged until a human, or the runner's
  unmeasured retry budget, ends it. **Open question for this strike:** should `run_job` end the pair
  when GitHub itself reports the runner offline for longer than G? That would be a counterparty
  signal, not the proxy's own accept path, so it is not Tesla's probe-starvation hazard.

**Interaction with `run-sandbox.sh`'s failure counter, and the nonce (new live evidence,
2026-11-03, from the #49 cutover).** `~/.arena-sandbox.fails` reached **5** in a 2026-08-19 burst
of empty registration-token mints. Only a **clean job** resets it, and sandbox jobs are rare
(Nick-authored issues take the privileged path), so it stayed at 5 for 2.5 months. On 2026-11-03
a **graceful `docker stop` of an idle runner**, done to refresh its spend nonce after `arena-auth`
was recreated, was charged as **failure #6**: `job failed (6 consecutive) — backing off 300s`
(verified: the file reads `6`, and the log shows `5 → 160s` then much later `6 → 300s` with no
reset). This is `concept_supervision_backoff_design_tension`'s stateful-counter fork, with a live
instance of the counter's state outliving its meaning. The recast multiplies the exits that hit it:
- **The sidecar gate must be infra, not job.** Proxy creation and the health gate run *before* the
  registration token is minted, so their failures must take the existing infra path (exit 1, no
  `FAIL_STATE` charge, no mint). The counter exists to cap the token-mint rate, and these mint
  nothing.
- **Pair teardown on proxy death must not charge it either.** When `run_job`'s `docker wait <proxy>`
  ends the pair (M11d), `docker run` returns non-zero, and today's code calls that a job failure.
  `run_oneshot`'s re-probe can't tell, because the proxy is already gone with the pair. So `run_job`
  needs a distinct return code ("pair ended because the proxy died") that `run_oneshot` treats as
  infra. An operator or autopull stop of an *idle* runner is the same case (today's 300 s, above).
- **The fork must be decided, not inherited.** With "only a clean job resets" and a counter already
  at the cap, every non-clean exit under the recast waits 300 s before the next pair, so each proxy
  death becomes a 5-minute outage. Two options: (a) **reset on successful registration** (runner
  observed online, the same counterparty signal as the off-box check) and charge only "token minted
  → never registered", which is the producer the counter exists to cap; or (b) **go stateless**:
  drop the file and rely on launchd's 10 s throttle, accepting ≤ 6 mints/min on a deterministic
  registration failure. (a) keeps a state file under `set -e` (the class that regressed twice);
  (b) deletes it.
- **The nonce coupling survives the recast unchanged.** `run_job` mints the `arena-auth` nonce at
  *registration* (`run-sandbox.sh:170`, before `docker run` at `:186`), so an idle runner holds a
  nonce for its whole idle life, and any `arena-auth` recreate invalidates it. The recast doesn't
  move the mint point (the sidecar adds ~2–10 s before registration), so the chain "recreate
  `arena-auth` → stale idle nonce → stop the runner to refresh → charged as a failure" is still
  there. Removing the producer means minting lazily at job start, which is #35
  (https://github.com/daemon-engine-labs/the-building-repo/issues/35). Until then, the infra
  return code above at least stops the refresh-stop from being charged.

**The six class members (plus the facts and flaws from the strike) under the recast:**

| Member | Under the sidecar | Status |
|---|---|---|
| 1. Silent relaunch loop | The proxy has no loop of its own. A proxy that can't start means the runner never registers, which the off-box check reads from GitHub and pages on every run. No counter exists to reset (Noether's flaw). | **Deleted**, with a detection bound equal to the off-box check period |
| 2. Postcondition passes a dead proxy | The gate is `healthy` (observed), then registration through it (end to end) | **Deleted** |
| 3. Remove before create | The old proxy is removed only when it has no client (its runner is gone) | **Dissolved** |
| 4. Wedged-but-Running reused | Never reused. A wedge mid-job dies with the job's pair. A wedge while idle breaks the runner's long-poll, so the runner goes offline at GitHub and gets paged. | **Dissolved** (detect bound = check period) |
| 5. Reuse blind to flags/mounts | No reuse: every runner start creates from the current spec | **Dissolved** |
| 6. `--internal` assumed | Asserted fresh at every runner start, before mint | **Residual check**, narrowed per Tesla: a root-equivalent actor can still enter the namespace and add a route, and no check here can stop that |
| Merged-is-not-live (egress) | autopull already relaunches idle runners onto merged code, and each relaunch builds a fresh proxy. A busy runner finishes one job on the old policy (Carnot's revocation point, bounded to one job). | **Dissolved** |
| M1 (a stopped container keeps its network entry) | Membership is never read as liveness | Absorbed |

**New risks the recast adds (priced, not hidden):**
- **Per-job latency** of about 2 s (M10) before each registration.
- **Single sandbox runner per host.** The singleton name `egress` stays correct only under the
  single-host, single-sandbox-runner assumption `arena-autopull.sh` already names. Scaling to N
  runners needs per-runner proxy names, and the runner's `HTTPS_PROXY` pointed at its own proxy.
- **Orphans on SIGKILL** (autopull's `kickstart -k`): `run_job`'s cleanup doesn't run. That's
  covered by `rm -fv egress` at the next start and by adding the proxy to autopull's reap of stale
  containers.
- **A wedge while idle is noticed at the check period, not immediately.** Nothing on the box
  recreates a wedged-but-alive proxy while its runner idles. Accepted, because demolishing on health
  is the probe-starvation hazard. If the bound is too slow, make the runner's own long-poll failure
  end the pair (to measure: does the Actions runner exit, or retry forever?).

**Claims to falsify in the re-strike:**
1. ~~The runner's long-poll goes through `HTTPS_PROXY` for its whole idle life~~: **measured at the
   minutes scale (M11b)**. Not measured over hours.
2. ~~When the proxy dies while the runner is idle, it shows offline within minutes~~: **measured,
   ≤ 33 s on death and ≤ 64 s on a wedge (M11c, M11f)**. But M11e shows a recreated proxy heals the
   old runner silently, so "nothing recreates the proxy mid-life" is now load-bearing.
3. `rm -fv egress` at `run_job` start can never hit a proxy another live client uses (single
   sandbox runner per host, enforced by one launchd label). M11e raises the stakes: a violation
   wouldn't just break a client, it would silently heal an orphan.
4. A GitHub-hosted scheduled workflow can read the runner list with a token that has no
   repo-write capability.
5. **New:** every way the pair can end has a defined `FAIL_STATE` classification (gate failure,
   proxy death, idle stop, job failure, clean job), and the counter fork is decided. See "Interaction
   with `run-sandbox.sh`'s failure counter" above.
6. **New:** an idle wedge ends somehow. Today nothing ends it (M11f), so either accept "page and a
   human ends it", or add an end trigger that doesn't share the proxy's accept path.

**Open variables (Nick's):** the paging channel (non-public: a private repo issue, or a push
service through a workflow secret), the check period and the offline grace T, and whether
`--start-interval` (Docker ≥ 25) is acceptable as a hard dependency.

**Shared helper (#47).** `arena-auth` is *not* a per-job sidecar: it holds spend state (nonces) across
jobs, so its long-lived reconcile problem is real. The long-lived-frame fold-backs in `TEMPER.md`
(serialize, validate before publish, an IP rather than an alias, network ID in the spec,
provenance-only labels) are the right inputs for `arena-auth`'s design, not for this one.

## ROUND 2 FOLD (dt-egress45-r2, 2026-11-03): what the re-strike changed in the sidecar

**Verdict of the re-strike: RECAST, 4/4, 0 DISSOLVE.** The sidecar frame held under every family,
and every fatal flaw sits inside it. Full strikes are in `TEMPER.md` (round 2). This section **amends
the RECAST above**: where the two disagree, this section wins. Folded once, as the directive
requires; **not re-struck**. Status: `RECAST (round 2 folded) — UN-TEMPERED for build until a
round-3 strike` (≤ 3 rounds).

### F1. One identity per pair. The stable dial name `egress` is deleted (all four families)
The recast justified `docker rm -fv egress` at `run_job` start with "the proxy's only client doesn't
exist yet", and claim 3 with "one launchd label". Both are false under SIGKILL. launchd serializes
*scripts*, not *containers*, and `kickstart -k`, OOM, and manual kills skip `run_job`'s teardown, so
the runner **container** survives, still registered (M11d: it retries, it doesn't exit). The next
`run_job` republishes `egress`, and **M11e** heals the orphan onto it within ~30 s. That leaves two
registered runners on one wall, one of them unowned, and erases the offline blip the pager needs.
**Make the heal unproduceable rather than guard it:**
- Each `run_job` mints a pair id (`P`) and names the proxy **`egress-$P`**. The runner gets
  `HTTPS_PROXY=http://egress-$P:8888` and nothing else. An orphan keeps dialing a name that **never
  reappears**, so no successor can answer it. Both containers carry the label `arena.pair=$P`, and
  teardown and waits use the **container IDs captured at create** (Carnot), never names.
- **Start sweep, in this order:** (1) every container labelled `arena-runner=sandbox`: de-register
  its GitHub runner, **verify 404**, then `rm -fv`; (2) then every proxy labelled `arena.pair`.
  Runners first, because reaping a proxy while its runner survives is exactly the M11e path.
  `arena-autopull.sh`'s reap gets the same order.
- *Optional, not required:* a private `--internal` network per pair (Carnot). Unique names already
  close the heal, since orphans dial by name. If adopted, note the constraint: the runner still
  needs `arena-auth` on `arena-internal`, so the topology becomes pair-net = {runner, proxy},
  `arena-internal` = {runners, arena-auth} with **no proxy on it**, and `arena-egress` = {proxies,
  arena-auth}.

### F2. The failure counter: decided, stateless (all four; three explicitly chose this)
`~/.arena-sandbox.fails` and its backoff ladder are **deleted** for the sandbox runner. launchd's
`ThrottleInterval 10` already caps registration-token mints at ≤ 360/h. The file was measured
lying: stuck at 5 for 2.5 months, then a graceful idle stop was charged as #6 → 300 s. A state file
under `set -e` is also the class that regressed twice. `run_job` still returns distinct codes (gate
failure, pair ended by proxy death, idle stop, job failed, clean), **for the log and the event path
(F3), not for any state.** (The privileged runner keeps its own counter. Changing it is outside this
design.) The nonce minted at registration (`run-sandbox.sh:170`) is still a live coupling; #35
(https://github.com/daemon-engine-labs/the-building-repo/issues/35) is its producer fix, and the
refresh-stop is no longer charged because nothing is charged.

### F3. The pager pages the *difference*, keeps its own history, and has a dead-man (all four, different facets)
- **Predicate:** `privileged runner online ∧ no online sandbox runner`, **observed in every one of k
  reads spread across ≥ T inside a single scheduled run** (e.g. 3 reads over 3 minutes). That makes
  the duration measurable without stored state (Carnot), lets normal between-job re-registration gaps
  (~12–18 s, M11a, plus a ~2–10 s pair birth, M10) pass, and stays **quiet when the whole host is
  down or asleep** (the privileged runner is offline too), so a sleeping Mac or a stopped colima
  doesn't train Nick to mute it (Maxwell, Tesla). Privileged traffic doesn't cross the wall, so the
  difference points at the wall/sandbox path.
- **Events for fast loops:** sampling can't see a pair that dies and recovers between reads (Carnot),
  so `run_job` **emits one event per pair that ends by proxy death** (its distinct return code) to the
  same channel, best-effort, with no stored state. If the writer itself can't run, the runner is
  offline and the differential predicate pages, so each covers the other's blind spot.
- **Dead-man for the checker (Noether):** the existing daily GitHub-hosted heartbeat reads the
  checker workflow's last successful run through the Actions API and pages if it is older than 2P.
- **Stated blind spot:** GitHub Actions scheduling *and* the box failing together page nothing.
- Still Nick's: the channel (non-public), the period P, T and k.

### F4. Idle wedge: how it ends (decided by M11g)
**M11g:** a runner behind a proxy that stays wedged **never gives up** (still running after 25 min;
GitHub offline from +78 s). `docker wait` doesn't return on a paused proxy (M5). So a wedged idle pair
lasts forever unless something ends it, and "measure first" (Maxwell) has now answered "something
must". The two proposed triggers conflict, and **Tesla's constraint wins:**
- **Rejected: end the pair when GitHub reports the runner offline for > G** (Noether). Offline is
  produced by wall ∧ GitHub ∧ runner, so a broker incident would demolish *every* healthy pair, and
  mid-job it would kill the job. That would add a producer.
- **Adopted: an idle-only local trigger.** `run_job` ends the pair when **both** hold: the proxy's
  own HEALTHCHECK has been `unhealthy` for ≥ N consecutive checks (M4: a wedge reads unhealthy), and
  the runner is **idle**, decided **locally** as "no `Runner.Worker` process in the runner container"
  (host-side `docker top`, no exec). Never during a job (so no probe-starvation hazard), and never
  from GitHub's runner list. The end is ordered: de-register the runner by name (verify 404), remove
  the runner container, remove the proxy, then return the infra code, which emits an F3 event.
- **A mid-job wedge** waits for the job to end (GitHub cancels it at the job timeout). The runner
  then has no Worker, and the idle rule ends the pair. That is bounded by the job timeout, and it
  is visible through GitHub's job failure.
- **Unmeasured, for round 3:** that "no `Runner.Worker`" is a reliable local idle signal, and how
  the runner behaves after a cancelled job while its proxy is wedged.

### F5. The thesis period, stated honestly (Tesla; Carnot)
The pair is scoped to a **runner registration**, not to a job. A sandbox runner idles for long
stretches (jobs are rare: the counter sat untouched for 2.5 months), so a pair can live for days.
What still holds over that idle age:
- **Policy can't drift mid-life.** The rootfs is read-only. The conf and allowlist are bind-mounted
  read-only from inodes that a git fast-forward *replaces* rather than mutates (verified in
  `arena-autopull.sh`'s notes), and nothing signals tinyproxy to reload. So the birth deny-canary
  sample stays valid for the pair's life, except for root-equivalent tampering (the P5 residual).
- **Liveness** over the idle age is GitHub's continuous long-poll view (M11b–c, M11f), read by F3.
- **Unmeasured and load-bearing:** the long-poll crossing the proxy over *hours* (M11b covered 240 s).
  F3's predicate is what would catch it failing.

**Alternative recorded, not adopted in this pass: a job-scoped pair.** Raise the pair only when a
`[self-hosted, sandbox]` job is queued, register a JIT runner (`generate-jitconfig`), and destroy
both when the job ends. That makes the birth sample cover the entire life, and "no online runner"
stops being an alarm at all. Cost: a **queued-job event source on the box** (a poller, or a webhook
relay), which is a new component whose silence is the original defect, plus per-job startup latency.
That's a frame decision for Nick, not something to fold silently.

### F6. The claims, narrowed (Noether, Tesla)
- Registration proves the **control-plane route** at birth. The deny canary proves **default-deny**
  at birth. Neither proves the allowlist is *right* for job traffic: a missing needed host shows up
  as a **job failure**, not through the wall's checks. That is now stated rather than implied.
- Member 1 ("silent relaunch loop") is **deleted only together with F3's event path**. Sampling alone
  doesn't delete it (Carnot).

### Fold-back of the class table (supersedes the recast's table where they differ)
| Member | Round-2 status |
|---|---|
| 1. Silent relaunch loop | Deleted with F2 (no backoff state) + F3 (events + differential page) |
| 2. Postcondition passes a dead proxy | Deleted (birth gate + registration) |
| 3. Remove before create | Dissolved; F1 makes it hold under SIGKILL too |
| 4. Wedge reused / never ends | Dissolved (no reuse). An idle wedge is ended by F4's idle-only local health trigger, decided by M11g. A mid-job wedge ends after the job timeout. |
| 5. Reuse blind to flags | Dissolved (no reuse, unique pair per start) |
| 6. `--internal` assumed | Residual check, asserted at every start |
| M11e silent heal | **Unproduceable** (F1 unique dial name + runners-first sweep) |
