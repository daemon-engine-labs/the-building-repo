# TEMPER.md — Egress wall lifecycle (#45)

**Overall verdict:** RECAST
**Struck:** dt-egress45 (2026-10-31). Families seated: Maxwell + Noether + Carnot + Tesla (4/4; Wu disabled). Every seat ran at the configured effort (Noether high, Carnot medium, Tesla medium).

## Per-family verdicts
| Family | Verdict | One-line |
|--------|---------|----------|
| Maxwell (Claude, the author) | DISSOLVE | The proxy's only client is an ephemeral runner. Tie the proxy's lifetime to it (a sidecar) and most of the machinery has nothing to guard. |
| Carnot (GPT-6.1-sol) | RECAST | Replacement and reporting don't establish the promised safety: an unvalidated successor gets live traffic, the swap drops connections, a label is provenance not state, a failed swap keeps a revoked policy, and the heartbeat can acknowledge itself. |
| Noether (DeepSeek V4.1 Flash) | RECAST | The signals conserve less than the invariant the design consumes them as: launchd `runs` resets on reboot, the reconcile is unserialized, a deny-only gate can't prove the route is *right*, and notification isn't exactly-once. |
| Tesla (Grok) | RECAST | The watcher is the unread log moved onto a GitHub issue. Alias-at-birth hands jobs an unverified route. Probe starvation can demolish a serving proxy. The network ID and `Internal` belong in `S`. |

**Synthesis rule applied.** One DISSOLVE (Maxwell, who is also the author) is a strong finding to fold, not a kill; ≥2 would have invalidated the candidate. Three seated adversaries, all RECAST. **Overall: RECAST.**

## Fatal flaws (deduped, most-severe first)
1. **Replacement exposes and drops traffic.** The successor is advertised (alias at birth) before it's validated, overlap DNS returns a chord that can include a dead address (M1 + M8), and removing the old proxy kills live flows; "zero DNS gap" is not connection continuity. *Carnot, Noether, Tesla.* → DISPOSITION: **dissolved by the RECAST** (the sidecar has no successor and no overlap: the proxy is validated before its only client exists, and removed only after that client exits).
2. **The reconcile is unserialized and its rename identity races** (concurrent reconcilers remove each other's winners and leave zero proxies; rename collisions). *Noether, Carnot.* → **dissolved** (one launchd job per label owns the proxy; `kickstart -k` is serial; nothing renames).
3. **The watcher protocol can't keep its promise.** launchd `runs` resets on reboot or reload, so a rebooted crash loop reads as improvement. Edge-only comments plus `updated_at` let the "nobody knows" state persist. The heartbeat can refresh its own evidence. A daily checker can't enforce a one-hour bound. A public issue is a beacon. An off-box checker sees the writer, not the wall. *Noether, Carnot, Tesla.* → **folded**: there's no box-side watcher and no counter. The off-box check reads **GitHub's own runner status**, and the runner long-polls GitHub *through the wall*, so its online state is a counterparty-written, end-to-end signal. It runs at least as often as its stated bound, pages on every non-all-clear tick, and uses a non-public channel. Two open variables, for Nick: the channel and the period.
4. **A deny-only health signal is weaker than the mint gate needs** (an over-blocking allowlist reads healthy forever). *Noether.* → **folded**: in the sidecar the runner's own registration traffic goes through the proxy, so a working allow path is a precondition of registering at all. The deny HEALTHCHECK gates *creation*, and registration proves *allow*.
5. **Probe starvation can demolish a serving proxy** (the HEALTHCHECK shares the accept path; a stuck CONNECT leads to unhealthy, then removal of the proxy with live flows). *Tesla.* → **folded**: health is used only as the **creation gate**, never as a demolition trigger. The pair is torn down only when a process actually exits. The scheduling assumption is stated next to M3.
6. **A same-named replacement network passes a name check.** *Tesla.* → **folded**: `Internal == true` is asserted at every runner start (fresh, not cached). The residual is narrowed to "a root-equivalent actor can enter the namespace and add a route, and no check here can stop that".
7. **A failed replacement keeps a revoked policy alive.** *Carnot.* → **dissolved**: no replacement-in-place. A new policy applies at the next runner start, an idle runner is relaunched onto merged code by autopull (idle-guarded), and a busy runner finishes **one** job on the old policy, which is bounded.
8. **A label is provenance, not current runtime state.** *Carnot.* → **dissolved**: no reuse, so no label is consulted.

## What holds (cross-family)
- M1–M9 are real measurements; M3 (a filter decision with no upstream) and M4/M5 (a wedge is visible to health, invisible to `docker wait`) were cited by every adversary.
- The deny-canary HEALTHCHECK is the right primitive, and it also proves default-deny is in force.
- R-a, R-b, R-d (with Tesla's scheduling caveat) and R-g hold. No FAIL_STATE for egress holds.
- Stateless condition-context loops are the right answer to the `set -e` regression class.

## Disposition
RECAST, folded once into `DESIGN.md` as the **sidecar frame** (per the directive: one recast pass, no loop). **The recast itself has NOT been struck.** It is `UN-TEMPERED (provisional)`, and a ≥2-family re-strike is required before building.

---

<!-- Per-family strikes below, in arrival order (Maxwell composed in-process first, then Carnot, Noether, Tesla). Arrival order, NOT a ranking. -->

## MaxwellMergeSlam's Design Strike

**Verdict:** DISSOLVE

**Summary:** The design hardens a long-lived, separately supervised proxy whose only client is an *ephemeral* runner. Tie the proxy's lifetime to the runner's and most of the machinery has nothing left to guard.

**Producer first:** The design's own table names the producers correctly (P1–P5). But it misses the **producer of the producers**: the proxy is a *long-lived singleton with an independent lifecycle*, supervised by its own launchd agent, while its sole client (the sandbox runner) is born and dies once per job. Every class member is a symptom of the two lifecycles being decoupled:
- **staleness** (members 4, 5, and "merged is not live") exists because the proxy outlives the jobs it serves;
- **replace-in-place hazards** (member 3) exist because there's a live proxy worth preserving;
- **drift detection** (spec label, wallwatch) exists because nothing naturally re-creates the proxy.

Can the producer be removed? **Yes. The proxy becomes a sidecar of the sandbox runner.** `run-sandbox.sh` creates it (fresh, current spec, on both networks) before registering the runner, gates registration on its HEALTHCHECK, and removes it when the runner exits. Then the spec label, the create-beside swap, the rename/alias dance, the run-egress supervisor poll, the egress LaunchAgent, and wallwatch's drift check all become unnecessary.

**Fatal flaws:**
- **Wrong option-frame (the crux).** "Keep the wall alive" assumes the wall must *be* alive between jobs. It doesn't need to be. Its only client is the ephemeral sandbox runner (the privileged runner has direct egress, and `arena-auth` does its own egress). Bind the proxy to the runner container's lifetime instead:
  - **Merged-is-live for free.** autopull already relaunches idle runners onto merged code, and each runner start makes a fresh proxy from the deploy tree. That closes the egress half of "merged is not live" with zero new machinery.
  - **A wedge dies with its job.** A hostile job that wedges the parser (CVE-2026-3945) wedges only its own proxy, which is destroyed when that job's ephemeral runner exits. There's no wedged-but-Running state to detect later.
  - **Nothing to replace in place.** A new runner always gets a new proxy, so remove-before-create can never drop a serving proxy.
  - **Visibility comes from the counterparty.** A proxy that can't come up means the runner never registers. GitHub shows the sandbox runner offline, and jobs visibly queue: the ACK is written by GitHub, not by a watcher we must keep alive.
- **Unstated assumption: the watcher's own liveness.** wallwatch is one more LaunchAgent, and its death is caught by a *daily* heartbeat, so "nobody knows" survives for up to 24 h. The design moves the silent-failure point; it doesn't delete it.
- **Missing failure mode in the swap (if kept).** Between `rm` of the old proxy and `docker rename` of the successor, by-name inspects (`run-sandbox.sh`'s gate, `run-egress.sh`'s poll) see no container called `egress` and report the wall down. The alias keeps DNS alive, but the scripts don't read DNS.
- **Under-counted blast radius of the sidecar alternative (named, so it's priced).** A SIGKILLed `run-sandbox.sh` (autopull's `kickstart -k`) skips its teardown and orphans the proxy. That's the same orphan pathology autopull already reaps for runner containers, so the next runner start must `rm -fv` any leftover proxy before creating, and autopull's reap list must include it.

**What holds:**
- M1–M9 are real measurements and stay true under either frame.
- The deny-canary HEALTHCHECK is the right liveness primitive: upstream-independent, it proves default-deny is in force, and it can be measured. Under the sidecar frame it becomes the runner's **registration gate**, not a continuous supervisor.
- `Internal == true` as assert-and-refuse is correctly argued as a residual check (a root-equivalent actor owns the docker socket).
- Rejecting FAIL_STATE for egress is right. The sidecar frame strengthens it: the proxy has no relaunch loop of its own to back off.

**If RECAST, what to fold back:**
- Lead with the sidecar decomposition as the candidate and demote "long-lived wall + reconcile" to the rejected alternative. Keep the long-lived design's sections only as the fallback if the sidecar's teardown or orphan story fails a measurement.
- Measure before committing: how long the HEALTHCHECK takes to report `healthy` at runner start (it gates every job's registration), and whether an idle runner's GitHub long-poll survives through a fresh per-runner proxy for hours.
- Re-run the class table against the sidecar. Expect: 2, 3, 4 and 5 dissolve outright; 1 becomes "the runner never registers, and GitHub shows it"; 6 stays assert-and-refuse.

John McClane: "Come out to the coast, we'll get together, have a few laughs." The wall doesn't need to outlive the party.


---

## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** The health observation is useful; the replacement and reporting protocols do not establish the promised safety. No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. Here, entropy enters through shared DNS, destructive cleanup, and a heartbeat that can acknowledge itself.

**Producer first:** The harm is interrupted sandbox connectivity, traffic through an unintended policy, or an outage nobody notices. Crashes, hostile requests, and daemon failures are triggers. Our producers are publishing a successor before validation, deleting containers carrying live connections, treating a creation label as current configuration, and treating general issue activity as watcher acknowledgement. These producers can be restructured as described below. Proxy failure itself cannot be eliminated by lifecycle code, so serving probes and independent failure reporting remain justified. The shared Docker daemon also permits external mutation; under that ownership model, configuration assertions remain necessary.

**Fatal flaws:**
- Make exposure to an unvalidated successor impossible: create and validate it without attaching it to the sandbox network or publishing the client alias; publish only after acceptance. Then a readiness check need not guard traffic already reaching it. Step B4 currently gives the successor the live alias before waiting for health. M8 explicitly establishes that DNS returns both addresses during overlap. A broken or permissive candidate can therefore receive real requests before acceptance, and removing it afterward cannot reverse those requests.
- The zero-gap claim measures DNS continuity, not connection continuity. Removing the old proxy terminates connections it owns; renaming the successor does not transfer them. Clients may also retain the old address after removal. Failed replacement preserves the old process, but successful replacement can interrupt jobs. Fold back to a declared interruption policy: quiesce and drain jobs before replacement, or explicitly design connection draining and client reconnection. The simpler maintenance boundary deletes much of the handoff machinery.
- A spec label records intended creation inputs; it does not establish current runtime state. A container can retain S after network disconnection or other runtime mutation. Moreover, healthy on localhost does not establish reachability from arena-internal. M1 disproves membership as liveness; it does not make membership unnecessary for connectivity. Removing that invariant conflates two independent properties. Either establish exclusive lifecycle ownership that prevents mutation within the supported model, or retain current configuration reconciliation and describe labels as provenance.
- The reconcile is neither serialized nor recoverable as written. Concurrent invocations can collide on egress-<S:12>; recovery can find a healthy matching successor while the old container still owns the name egress, making B3's rename fail. Replacing an unhealthy container already named egress-<S:12> also encounters a name collision. Fold back by eliminating the rename-dependent identity: address clients through the alias, give attempts unique identities, serialize lifecycle mutations, and explicitly recover each interrupted publication/removal state.
- The dead-man's switch observes the wrong producer. Issue updated_at can advance because of a human edit or the heartbeat's own stale-warning comment, without any successful watcher tick. A daily reader also cannot enforce an hour-scale detection promise; detection can take roughly a day or longer. Store an explicit watcher-owned last-success timestamp that heartbeat comments cannot refresh, and schedule the independent reader to meet a stated detection bound. Remote acknowledgement is still persisted state, with read/write failures and first-run recovery to specify.
- Preserving the old proxy after every failed replacement confuses availability with policy correctness. If S removes a previously allowed destination, retaining the old wall indefinitely preserves the very permission being revoked. Drift reporting does not make that permission safe. Define which changes require a fail-closed activation boundary; quiescing sandbox work during policy activation is a simpler option than promising uninterrupted service through an obsolete policy.

**What holds:**
- A local deny probe improves substantially on Running and docker wait for detecting a wedged proxy.
- Keeping upstream availability out of automatic restart decisions avoids coupling recovery to GitHub outages.
- An observer outside the proxy plus an off-host observer addresses distinct failure domains, provided their acknowledgement protocol is explicit.
- The measured per-network alias behavior and explicit Internal assertion are useful evidence and invariants.
- Dijkstra: "Simplicity is prerequisite for reliability." The single run-arguments definition moves in that direction.

**If RECAST, what to fold back:**
- Narrow the promise to bounded detection and explicitly defined replacement interruption; remove the absolute 'unreachable' claim.
- Prefer a quiesced replacement boundary if uninterrupted jobs are not a requirement. If they are, budget for an actual traffic handoff and draining protocol.
- Stage candidates outside the client network, validate them, then publish them under a serialized, recoverable lifecycle.
- Separate local serving health, current configuration correctness, sandbox reachability, and upstream availability. Each answers a different question.
- Use a watcher-owned acknowledgement timestamp and explicit notification state; define stale detection, reporting failures, counter resets, and policy-revocation behavior before implementation.


---

## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The invariant this design claims to conserve is *"the wall is up, and it is the right wall"* — but its three load-bearing signals (the deny-only HEALTHCHECK, the launchd `runs` count, and the unserialized create-beside swap) each conserve strictly less than that, and the design consumes them as if they conserved the whole.

**Producer first:**

- **Bad outcome: a dead or wedged proxy is reported as up.** Producer: the reuse test / postcondition reading `State.Running` (P1). *Deletable — yes.* Replace the metadata read with an observation of serving; the design does this. **But** the replacement (deny-canary `403`) conserves *denies*, not *allows*. The producer is narrowed, not deleted: the code that says "the wall is up" now means "the wall denies," and the mint gate treats those as equal. See Fatal flaw 3.
- **Bad outcome: a relaunch loop is silent (31,136 deaths, nobody knows).** Producer: launchd converting death to relaunch with no observer (P4). *Deletable in principle* — add an observer. The design adds one, but its conserved quantity (launchd `runs`) is **not conserved across a reboot or plist reload**, so the loop goes silent again the moment the counter resets. Producer survives. See Fatal flaw 1.
- **Bad outcome: a failed create leaves no proxy at all.** Producer: destroy-then-create on a singleton name (P3). *Deletable — yes*, create-beside-then-swap; the design does it. **But** the reconcile that performs the swap is not serialized, and the swap step (`rm` every other labelled container) can be executed by two reconcilers against each other, removing the winner. The P3 harm is reintroduced through the concurrency path. See Fatal flaw 2.
- **Bad outcome: silent drift in everything outside the reuse subset.** Producer: the reuse test re-deriving desired state (P2). *Deletable — yes*, one written spec stamped as a label; the design does it, and the spec covers the image ID, so the "rebuilt binary under the same Dockerfile" hole (claim 6) is closed.
- **Bad outcome: a wall with a hole reported as a wall.** Producer: existence of `arena-internal` taken as proof of `--internal` (P5). *Not deletable:* the producer is a root-equivalent actor holding the docker socket, which is outside any arena design. The assert-and-refuse residual is the honest answer, and the reason given (root-equivalent socket holder) is the correct one. This is a check that should stay.
- **Bad outcome: nobody is notified of a transition.** Producer: the watcher's read-modify-write of the pinned issue body, which assumes read-your-writes on GitHub. Restructurable — make the notification append-only/idempotent and derive state from GitHub's own timeline rather than from a body it must have written last. See Fatal flaw 5.

**Fatal flaws:**

- **The conserved count is not conserved (P4 / section E).** `launchctl print … runs` counts starts *since the job was loaded*. A reboot, a logout, a `bootout`/`bootstrap` of the plist, or an installer re-prepare resets it to zero. The design then reads the *previous* value from GitHub and computes a rate — but a reset makes the delta negative, and the design defines no behavior for a decrease. The worst case is exactly the class this design exists to delete: a box in a relaunch loop reboots, `runs` reads `3` against GitHub's stored `31,136`, the rate looks *better* than before, and the loop is silent again. "The counterparty writes the ACK" does not repair this: the ACK is the *derived rate*, not the counter, and the only source of truth for the counter is the volatile OS object. A symmetry (reboot) has no conserved quantity.
- **Reconcile is not serialized; the singleton is protected by a name, not a lock (section B.4).** Three producers can start a reconcile: launchd's relaunch, `arena-autopull`, and the design's own *proposed* auto-activation of spec drift (open variables). Two concurrent reconciles with the same `S` collide only on the deterministic `egress-<S:12>` name; with different `S` (a mid-merge config edit) they do not. Both then execute "remove every other `arena.wall=egress` container, plus the legacy `egress`." Reconciler B's removal filter matches A's freshly-renamed winner; reconciler A's filter matches B's successor. The result can be **zero proxies** — the exact P3 harm, reintroduced by the path the design does not model. The invariant "exactly one reconciler runs at a time" is assumed and never stated or enforced.
- **The health signal is weaker than the invariant the gate consumes it as (sections A, D; R-d).** The HEALTHCHECK proves *answers* and *default-deny*. It does not prove the allow path. The mint gate (D) asks `egress is healthy` and mints on that — so an allowlist that silently over-blocks (someone edits `egress-allowlist.txt`, `S` changes, the swap succeeds, the new proxy denies a host jobs need) reads **healthy forever**, jobs mint, run, and die at the wall. That is the *"wrong route"* half of the design's own stated harm. The design reports it (watcher allow-canary, report-only) but does not gate on it. R-d's reasoning — "don't couple recreate to GitHub's availability" — is correct for the *recreate* decision and wrong for the *mint* decision; the design already separates those two consumers and then feeds both the same weak signal. The gate must consume the signal that actually means "the route is right."
- **The swap force-removes a proxy that in-flight jobs may be using (section B.4; M8; claim 4).** M8 proves the DNS *name* survives rename and the overlap, and claim 4 covers `docker rename`. Neither covers `docker rm -fv` of the old container while a sandbox job holds a connection *through* it. The "no gap" claim is DNS-level, not connection-level; the blast radius includes a running job whose egress dies mid-request. The design's own frame — "down … and nobody finds out" — is violated in the *known* direction here, and the fix is structural (remove the old proxy's `egress` alias first so it stops taking new connections and drains, then remove), not a better check.
- **Exactly-once notification is not conserved (sections E, F).** The watcher decides "transition" by reading the previous body from GitHub, then rewrites it. A body write that fails after a computed transition re-reads the old body next tick and comments again; a flapping wall at a 300 s tick can comment-storm into GitHub's rate limit — at which point the *entire* "somebody finds out" mechanism degrades silently, which is the success-equals-absence defect the watcher and heartbeat exist to remove. There is no compare-and-swap on the issue body, and the read-modify-write assumes read-your-writes on an eventually-consistent API.

**What holds:**

- **Create-beside-then-swap** correctly deletes the destroy-then-create producer — the structural idea is right; it needs serialization and a drain, not replacement.
- **The single spec label `S`** (image ID + run-args array + conf hash + allowlist hash) is the right conserved quantity for drift, and hashing the image ID closes the "rebuilt binary" hole.
- **Observing serving instead of inferring it** (M4: `SIGSTOP` → `running=true`, `health=unhealthy`; M5: `docker wait` blind to a wedge) is a real deletion of the "wedged-but-Running reused forever" class.
- **The `Internal == true` assert-and-refuse**, with the stated reason that a root-equivalent socket holder is outside the trust boundary, is honest and correctly residual.
- **M7/M8** (per-network alias form; no DNS gap across overlap and rename) are load-bearing and measured, and R-g correctly rejects the tempting `--network-alias` form.
- **The dead-man's switch for the watcher (F)** — checking the watcher's own liveness from off the box — is the right instinct, and its failure is downstream of Fatal flaw 1 (the counter) and 5 (the notification), not of its own shape.

**If RECAST, what to fold back:**

- **Make the relaunch counter conserved across the symmetry it must survive.** Either read a boot-stable identity (`kern.boottime`) and treat a change as a *reset event* rather than a negative delta, or — better — make the *counter itself* counterparty-owned: have each supervisor start append a monotonic marker to a bounded ring (the pinned issue's timeline, or a dedicated issue), so the count lives where the ACK lives and reboot cannot erase it. Define the reset semantics explicitly in E; do not leave a decrease undefined.
- **Serialize the reconcile and make the swap safe under concurrency.** Take an `flock` (or a docker-label lease) around B; give each attempt a unique successor name; choose the winner by the atomic `docker rename` to `egress`; and forbid the swap from removing any container it did not itself create this run. State the invariant "at most one reconciler, and it never removes a peer's winner."
- **Gate the mint on the signal that means "right," not the signal that means "denying."** Move the allow-canary verdict (currently watcher-only, report-only) into the pre-mint gate (D), or add a locally-served allow probe so the allow path is observable without depending on GitHub. Keep the *recreate* decision gated on deny-health — R-d is right about recreate, wrong about mint.
- **Drain before removing.** In B.4, remove the old proxy's `egress` alias first so it stops accepting new connections, then remove it; or state and accept the connection-drop blast radius. Update claim 4 to cover `rm`, not just `rename`.
- **Make notification idempotent and append-only.** Drive transition detection from GitHub's own timeline (the previous comment's state) rather than a body the watcher must have written last; treat a failed body write as "no transition emitted," never as "re-emit." Add an explicit rate-limit/failure mode for the notifier itself, since it *is* the "somebody finds out" path.
- **Add the two missing invariants to "Claims to falsify":** (a) `launchd runs` is monotonic for the lifetime of the watcher's world; (b) exactly one reconcile runs at a time. Both are currently assumed and both are false on the path.

---

## Tesla, the Arc-Prophet's Design Strike

**Verdict:** RECAST

**Summary:** The wall is taught to sing, then the song is published on a frequency that goes quiet while the wall is wrong, and during the swap the name `egress` rings two bells at once, one of them a corpse.

Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration."

**Producer first:** The design hardens checks. The producers underneath them:

1. **Down or wrong, and the phone stays dark** (the harm named in the opening of DESIGN.md). Triggers stay external: segfault, CVE wedge, full disk, colima flap, a lost `gh` call. The new producer is ours, in sections E and F. The watcher rewrites one issue body every tick, so `updated_at` stays fresh, and it speaks only on an edge (healthy ↔ degraded, or a `runs` delta). Spec drift and the allow-path are "reported but never acted on," so they never enter that edge. The daily heartbeat polices the timestamp. This producer can be deleted. GitHub becomes write-only output. While the snapshot is not an all-clear, every tick pages. The off-box job pages unless the snapshot is fresh and says healthy, spec-match, internal, deny-403, and allow-200. The previous-body diff then produces nothing. A crash loop that heals inside the sample window still needs two values of launchd's `runs`; that memory can live in a local file on the watcher only, because a parse failure there is itself a page, and that file is off the proxy's `set -e` path.

2. **A job is handed a route the gate did not verify.** Trigger: create-beside, or a flap that leaves a stopped container. Producer is ours, section B.4 together with M1 and M8. The live alias `egress` is attached at create, before `healthy`, and a stopped predecessor keeps its network entry, so the name is a chord of addresses. Section D's gate inspects the container *name*, a different object from the alias the sandbox dials. This producer can be deleted. The route the job receives is the single IP of the container the gate just found healthy. The alias is not the cutover, dual DNS cannot occur, and no cardinality check is required.

3. **Probe starvation destroys the serving wall.** Trigger: one allow-path CONNECT that never completes. Producer is ours, sections A, C, and B.4. The HEALTHCHECK shares the proxy's listen path with the job, and `unhealthy` means the supervisor exits and reconcile removes the old container as soon as an idle successor is healthy. M3 shows the filter's *decision* is upstream-independent. The *turn* the probe waits for is not, and R-e calls the proxy agnostic, so the design refuses to assume a concurrent accept loop. This producer can be restructured. A data-plane probe timeout must not remove a proxy that still owns established flows. A second, richer grep does not delete it. A check path that is outside MaxClients and outside the client accept queue would delete the coupling, if the image actually has one.

4. **A hole that still answers to the name `arena-internal`.** Trigger: the network object is recreated, or a pre-existing open network is reused. Producer is ours (P5, sections B.1 and D): the wall's identity is a string. The stated reason it cannot be deleted ("the arena would have to own the daemon") is too large. The non-root producer is deleted by creating that network in the reconcile and stamping its ID and `Internal` into `S`, so a same-named replacement is a different wall and will not be reused. What cannot be removed: a root-equivalent socket holder can `nsenter` and add a route. That harm is the hostile input itself. The residual covers only that actor, and it belongs in the level-triggered snapshot. A point-in-time assert at mint goes stale as soon as the job is running.

P1's inference from docker metadata, P3's remove-before-create, and P4's total lack of a signal are restructured in the doc. I am striking the producers the restructure put in their place.

**Fatal flaws:**
- Make the silent wrong wall impossible: delete the edge detector and the `updated_at` dead-man (sections E, F, M9). Section F asks a daily `heartbeat.yml` to notice an issue older than an hour. A daily oscillator enforces a one-day bound; the one-hour sentence is unmet by the schedule named beside it. The periods on the page are 300 s, 3600 s, and 86400 s, and the middle one is a wish. A transition comment is a single pulse. After it fires, body rewrites keep `updated_at` young, so the heartbeat is satisfied while the body says drifted, or while the allow-path has been failing since 3am. A lost `gh` comment does not re-fire: the baseline already moved. That is the unread log of 31,136 deaths, transposed onto a GitHub issue. The body is also a state file, the class that regressed twice under `set -e`, now an input, on a public repo (open variables), editable by anyone who can edit the issue. M9's word "independent" overclaims the same circuit. A GitHub-hosted runner has no path into an `--internal` network. The heartbeat can prove the writer is speaking. It cannot prove the wall. A watcher that writes a cheerful snapshot on schedule is invisible to it, compromised or merely buggy.
- Make the unverified route impossible: delete alias-at-birth (section B.4, M1, M8, claim 3). M8 records that overlap DNS returns both IPs, then calls the swap viable because one later probe succeeded. One probe is one sample of a chord. M1's stopped container remains in the network, so after the colima flap the design itself lists as a trigger, the chord contains a dead address. The gate can see container `egress` healthy while the job's resolution hits the corpse, or hits the successor that was advertised at create, before the HEALTHCHECK passed. If the new process accepts before default-deny is loaded, that window is a hole with the wall's name on it. Claim 3 (colima restart, and the legacy unlabelled `egress` as the old member) is load-bearing and unmeasured.
- Make probe-induced demolition impossible (sections A, B.4, C, claim 1, R-d). Claim 1 counts MaxClients at 100 and one job. The future input is one CONNECT to `api.github.com` that never returns, queued ahead of `CONNECT wall-canary.invalid:443`. The supervisor breaks on `running/unhealthy`, launchd adds a `run`, an idle successor goes healthy immediately, and reconcile removes the container the job is still attached to. R-d kept the allow path out of the HEALTHCHECK so a GitHub outage would not flap recreate. Head-of-line blocking on a single accept path puts that outage back through the side door. The `runs` storm will be read as the wedge tracked in #48, and the open threshold of 3 will get tuned while the coupling stays.
- Make "right name, wrong object" impossible for everyone short of root (P5, the spec definition, sections B.1 and D, the class-member table). `S` hashes image ID, the run-args array, and two file hashes. It does not hash the network ID or `Internal`. The assert samples a mutable shared object at raise and at mint, and section E never reads `Internal` again. A replaced network that keeps the name passes the next name check. Stamping the ID into `S` deletes that producer. Owning the daemon does not. Root `nsenter` remains the residual, and the doc should say that and stop.

**What holds:**
- M3 holds. `403` on `wall-canary.invalid` is the filter judging the host string, with no DNS and no upstream. An allowlist widened until the canary matches turns the wall unhealthy. That is the right direction of coupling.
- R-d holds once flaw 3 is folded: an allow-path failure pages and does not recreate.
- "Remove the old container only after the successor is healthy" holds as the deletion of P3's zero-proxy hole, once that successor is no longer advertised by the alias at birth.
- Image ID inside `S` covers a binary rebuilt from the same Dockerfile (claim 6).
- The loop in section C sits in a condition context. `set -e` will not abort it. That is a real answer to the two FAIL_STATE regressions, on this script.
- R-a and R-b hold. Docker does not restart on unhealthy, and a healer with the docker socket mounted is root inside a container.
- M7 holds. The short `--network-alias` form lands on the first network only. The per-network form is the one the measurements support.
- Leaving the runners' FAIL_STATE fork and `arena-auth`'s token bytes out of this design holds. If that spec is ever hashed, hash the variable names only.
- `docker rename` is metadata on the container object. An established TCP to its IP survives the rename (claim 4). The drop happens later, when the old container is removed, or when a client resolves the shared alias onto the wrong IP.

**If RECAST, what to fold back:**
- Sections E and F. The issue body is a snapshot written every tick: health, computed `S` against the label, network ID, `Internal`, deny result, allow result, current launchd `runs`, last exit code, last exit time, watcher time. It is an output. Nothing reads it back as memory. A local last-`runs` file on the watcher is allowed; if it is missing, unreadable, or the counter moves backwards, that tick is degraded. Any tick whose snapshot is not an all-clear posts a comment, including spec drift and a non-200 allow probe. Allow-path failure does not recreate (R-d stays). The off-box checker runs at least as often as the bound it enforces (hourly checker with a one-hour bound, or change the bound to the real period) and it pages when the snapshot is stale or is not all-clear. State in F, in one sentence, the limit M9 cannot cross: this checker sees the writer, and it has no path to the wall.
- Close the open variable on where the issue lives. The pulse does not go on the public repo. A world-readable "wall down" is a beacon. The channel is one the box's `gh` identity can write and humans do not edit by hand.
- Section B.4 and section D. Create the successor on both networks without the client-facing alias. Wait until it is `healthy`. The pre-mint gate passes the sandbox that container's IP as its only route. Old flows keep the old IP until they end. Disconnect every other `arena.wall=egress` container from `arena-internal` before those addresses can still be chosen, then remove them and rename. Alias `egress` is for humans and for `docker exec`, if it remains at all.
- Sections A and C. Write the scheduling assumption next to M3 as load-bearing: the deny canary is only equivalent to liveness if the proxy can answer it while an allow-path client is stuck. Where that is false, `unhealthy` from a probe timeout leaves a proxy with established connections in place; the successor waits beside it. Dead process, or a deny canary that answers with something other than `403`, still replaces.
- The spec definition and the P5 paragraph. `S` includes the docker network ID and `Internal`. Replace "we would have to own the daemon" with the narrower residual: root can enter the namespace and add a route, and no check in this design can stop that.
