# CRUCIBLE — Safe untrusted `build-sandbox` propose path

**Ore (pre-selected):** complete `build-sandbox` in `triage.yml` so a non-allowlisted / bot-authored
issue actually gets built and yields a reviewable PR — without breaking the arena's security model.

**Why this glows AND what it changes:** the arena already *produces* its own agenda (the heartbeat
self-generates issues) but **cannot build it** — every bot-authored issue (`app/github-actions`)
routes to the dead propose path. Issue #16 has sat unbuilt for 6 days for exactly this reason. This
is the single seam that reconnects the self-sustaining loop: fuel is being injected into a
disconnected crankshaft. Completing it turns the heat engine from hand-fed to autonomous.

**The spark:** the arena builds an issue *it wrote for itself*, opens a PR, and a human just reviews.

**Falsifier (what would prove this is slag):** if there is no safe way to run an LLM build on a
runner that eats attacker-controlled text — if every design leaks a credential or forges a
privilege-escalation path a human reviewer can't reasonably catch — then the honest answer is "the
untrusted path stays inert; only allowlisted humans build," and this ore is slag.

**Load-bearing assumption stated aloud:** an untrusted LLM build is worth having *at all*. If the only
issues we ever want built come from Nick, `build-sandbox` should stay a no-op and we should delete
the propose branch rather than complete it. (Counter-evidence: the heartbeat exists specifically to
generate a non-human agenda — so the untrusted path is load-bearing for the arena's stated purpose.)
