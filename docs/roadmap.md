# Roadmap

The at-a-glance index of planned work. Each item links to a stand-alone
description in [`backlog/`](backlog/). **Priority and status live here only** —
never in a backlog file.

- **Status:** ☐ not started · ◐ in progress · ☑ done
- **Priority:** High · Medium · Low · Launch (gated to before public exposure)

## Current focus — deployed-fleet performance and stability (order set 2026-09-02, re-ordered 2026-09-15)

The campaign's aim right now is making the *deployed* server and phone fleet
faster and more stable, and the historical enemy is unnecessary wire
traffic. Stability work went before performance work because the server
side had two known defects that outweighed any remaining inefficiency;
both shipped in v48 on 2026-09-16 and were confirmed fixed by the first
meeting on it ([2026-09-17 measurement](audits/2026-09-17-production-meeting-v48.md)),
so performance is next — with one open question riding along, whether the
server's inbound queue backs up at the peak of a meeting, now measurable
on every health line since v50. Work
proceeds in this order (owner-set; rationale for the original ordering in
the [retirement decision record](superpowers/specs/2026-09-01-swim-slimdown-decision.md)'s
review outcome and the parity program; re-ordered 2026-09-02 after the
purification batch merged):

1. **Stop the measured waste** — DONE AND DEPLOYED: stalled-range
   suppression in [Dart](backlog/engine-stalled-range-request-backoff.md)
   (7ebd076) and [Kotlin](backlog/kt-stalled-range-suppression-port.md)
   (gossip-kt bbbf31f); reached production 2026-09-02 via opendoor-api
   #17 (d89110a).
2. **Pace the server** — DONE AND DEPLOYED (same release):
   [wire-efficiency](backlog/kt-port-wire-efficiency.md) phase 1
   (gossip-kt 0dafefd). Validated on live devices before the merge:
   converged-link cadence fell 112 → 2-3 digest lines per 30 s (~50×),
   floors adopted at first contact with zero stalls.
3. **Deploy the server on the purified library** — **merged 2026-09-03 as
   opendoor-api 7be0f76** (PR #18, server 214/214, live-device validated
   on a Pixel 9 through the new ngrok runbook: converged link paced at
   30 s, presence pushes persisted contiguously, no errors); released as
   Heroku v45 the same day, and the sync-health visibility work (opendoor-api
   PR #20) followed as v46 on 2026-09-12. The opendoor-api submodule moved to
   gossip-kt 26e5e24
   ([domain purification](backlog/kt-pure-domain-concurrency.md),
   behavior-preserving; no server adaptation needed), released on its own
   so the refactor soaked before behavior changes landed on top of it. The
   post-deploy observables check for the 2026-09-02 release was closed by
   the 2026-09-15 measurement (idle gossip at 30 s, no stalled-range loop).
4. **Stability hardening batch (Kotlin)** — **merged 2026-09-15 as
   gossip-kt ea0d51c** (PR #8, real merge, nine commits, suite 1046 → 1067,
   three Codex passes). Cleared to start 2026-09-14: the
   [lifecycle rulings](superpowers/specs/2026-09-01-receive-loop-lifecycle-rulings.md)
   were audited and re-ruled (rulings 9–12), the plan re-baselined on
   gossip-kt 83ec65a, and the owner ruled Kotlin goes first on the relay
   retirement. Shipped: the Kotlin half of
   [retire indirect probing](backlog/kt-retire-indirect-probing.md) (removes
   the server's 500 ms receive-loop stalls) + the
   [coordinator lifecycle fix](backlog/kt-coordinator-restart-lifecycle.md)
   (a stopped node keeps merging; restarts stack listeners into
   duplicate-write failures) + [cancellation](backlog/kt-cancellation-swallowed.md),
   one batch.
5. ☑ **Deploy the Kotlin side** — **done 2026-09-15**: opendoor-api PR #21
   merged (real merge, 4b1cda7) and released as Heroku v47 at 21:59
   local; the health line is clean since. The bump went out **on its
   own** (owner, 2026-09-15): the
   [payload cap](backlog/kt-payload-size-cap.md),
   [get-or-create stream access](backlog/kt-get-or-create-stream.md), and
   KT-E's entry-ordering fix move to a later bump so this release has one
   suspect. Live-device validated through the ngrok runbook before the
   Heroku release.
6. ☑ **Server fixes from the meeting** — **done 2026-09-16**: opendoor-api
   PR #22 merged (real merge, 94d1f8e) and released as Heroku v48 at 20:15
   local. (Owner, 2026-09-15: the meeting's
   findings go before everything else): one opendoor-api pull request
   carrying [session ownership](backlog/server-session-ownership.md) (267
   sends to departed peers in one meeting) and
   [compaction under load](backlog/server-compaction-under-load.md) (every
   tick failed for three hours), live-device validated through the tunnel
   runbook, its own Heroku release. **Implemented and live-device
   validated 2026-09-16** (opendoor-api PR #22; spec
   `docs/superpowers/specs/2026-09-15-meeting-server-fixes-design.md`, nine
   rulings approved 2026-09-15; suite 264 → 289): compaction succeeded on
   five ticks under two heartbeating phones, and a reconnect over a
   half-open socket left zero dead-session sends with the old handler
   ending within a millisecond. The same afternoon's last meeting, read
   after the fact, showed both defects at full strength
   ([incident report](audits/2026-09-16-last-meeting-incident.md)).
7. ☑ **Measure** — **done 2026-09-17**: the first meeting on v48 (170
   minutes, 13 phones, 9 at once) read from the Papertrail archive
   ([measurement report](audits/2026-09-17-production-meeting-v48.md)):
   zero deaf-phone runs, both reconnects-over-an-open-socket displaced in
   the same second, zero failed compaction ticks with the presence log
   saw-toothing between 4,300 and 5,800 entries, 80 sockets at a median
   lifetime of 144 s (28 an hour against 48 on v47), eight ping timeouts on
   two phones, pending never above zero. Traffic is ~300 KB out per phone
   per minute, not 710 KB — the drop sits between v46 and v47 and is not
   explained by any pacing change, so the digest share must be re-measured
   on v48 before item 10's spec sizes its win. Two small follow-ups
   surfaced: the ping-timeout policy and an eleven-second inbound backlog
   at the busiest minute (nine to ten phones), read from sends to a peer
   removed eleven seconds earlier. Original brief: the
   next real meeting on those releases, read through the
   health and merge lines. **A second before-picture exists**: the last
   meeting of 2026-09-16 on v47, read from the Papertrail archive after a
   group reported the app going haywire near the end
   ([incident report](audits/2026-09-16-last-meeting-incident.md)): one
   phone deaf for 63 minutes, forty failed compaction ticks, a
   reconnect storm across seven phones in the final ten minutes; both v48
   fixes are sufficient to explain it. Watch for on v48: zero deaf-phone
   runs, a flat stored-entry count, and the socket-lifetime distribution
   (median 109 s on that network); also whether the half-second presence
   flicker seen through the tunnel on 2026-09-16 (the app's 6 s freshness
   bound against two gossip hops) shows on production. The **baseline exists**:
   [the 2026-09-15 meeting report](audits/2026-09-15-production-meeting-measurement.md)
   measured release v46 under up to seven phones — 710 KB out per phone per
   minute in a meeting, ~97 % of it digests, 450 MB out over three hours,
   pending never above zero. The next meeting should show the same traffic
   shape with steadier merges and no relay stalls (lifecycle bump), and
   zero departed-peer sends and zero compaction failures (server fixes).
8. ☑ **Finish the Dart half of the relay retirement** — **done 2026-09-18**
   (branch `feature/retire-indirect-probing`; rulings page
   [approved](superpowers/specs/2026-09-18-dart-relay-retirement-rulings.md)
   the same day): the indirect phase and the relay handler are gone, the
   grace window races the late Ack (the Kotlin flow-back adopted), ADR-004
   and ADR-012 are amended, the mechanism is no longer called SWIM, the
   asymmetric-partition suite pins the honest degradation with a third node
   present. Closes [retire indirect probing](backlog/kt-retire-indirect-probing.md)
   on both halves. **Remaining tail:** the OpenDoorApp pin bump (its own PR
   in the app repo, device-checked on Android and iOS per the rulings).
9. **The next Kotlin bump** (owner, 2026-09-16): the
   [payload size cap](backlog/kt-payload-size-cap.md),
   [get-or-create stream access](backlog/kt-get-or-create-stream.md), and
   KT-E's entry-ordering fix, held back from v47 so that release had one
   suspect. Both twins move together once the Dart half lands, so this
   rides right after item 8, as its own opendoor-api bump, live-device
   validated.
10. **Digest scoping to shared groups** — the first of the two remaining
   performance items:
   [only tell a peer about the groups you both belong to](backlog/engine-scope-digests-to-shared-groups.md).
   Spec first (it needs an owner ruling before code) — the spec can be
   written while items 8 and 9 are built, since it needs the owner's ruling
   before any code. The biggest measured waste by far: the 2026-09-15 meeting
   confirmed 710 KB out per phone per minute across up to seven phones,
   ~97 % digests — but the [v48 meeting](audits/2026-09-17-production-meeting-v48.md)
   measured ~300 KB at the same phone counts, so the digest share is to be
   re-measured through the tunnel on v48 before this spec claims a saving
   (the 2026-09-03 tunnel number was ~700 KB/min for one phone,
   almost all 8 KB all-channel digests sent about once a second because
   presence heartbeats keep the pacer at its floor (plus group and account
   ids disclosed to unrelated peers). Both twins.
11. **Wire-efficiency phase 2** — the second: recency suppression (skip the
   round with a peer exchanged with moments ago — removes most of those
   per-second digests outright), dominance-filtered and request-scoped
   digest responses, the digest budgeter (same
   [item](backlog/kt-port-wire-efficiency.md) as phase 1).
12. **Then** the [Dart minor-findings sweep](backlog/health-minor-findings-sweep.md)
    (two correctness latents), the
    [lifecycle batch follow-ups](backlog/kt-lifecycle-batch-follow-ups.md)
    with the [flaky timing tests](backlog/kt-load-flaky-timing-tests.md)
    first, and the smaller traffic items —
    [push scoping](backlog/engine-push-scoping.md) and
    [coalescing](backlog/engine-message-coalescing.md).
13. **Flip the fleet to v2** — deliberately waiting (owner, 2026-09-02):
    wire playbook steps 6–7, no dev work; v1's payload encoding costs ~3×
    the bytes of v2's on payload-heavy deltas. The coverage wave is rolling
    (the 2026-09-02 fleet app release, OpenDoorApp 00ec1682 on pin 2d6c618,
    is v2-receive-capable and floor-reporting); the flip happens when the
    owner judges coverage sufficient, independent of items 3–12.

Kotlin work ships via opendoor-api submodule bumps — items 1 and 2 rode
one bump (#17, deployed); item 3 rode #18 (v45); item 5 rode #21 (v47),
carrying item 4 alone; item 6 was a server-only release (#22, v48). The
payload-cap, get-or-create, and KT-E fixes ride the next Kotlin bump,
item 9.
Behind the list, the other parity-completeness items queue in the
*Kotlin port* track (probe-selection's behavior half, sync-activity API,
glossary, flow-backs, scenario sweep).

## Guardrails (design invariants)

Constraints that new work must respect (see `packages/gossip/docs/adr/`):

- **Single-isolate execution** — no locks; all engine state is touched from one isolate. (Dart. The Kotlin twin runs on a thread pool, and its locks live only in `infrastructure/` wrappers — machine-checked, see the [parity program](parity.md)'s exemption E3.)
- **~32 KB message cap** — the largest a single message may be on the wire (Android Nearby Connections + BLE frame codec share this limit).
- **≤ 8 devices per channel** recommended.
- **Transport- and discovery-external** — the library defines the `MessagePort` interface and is told about peers; it neither opens sockets nor finds devices itself.
- **Payload-agnostic** — the library syncs opaque bytes; the application defines their meaning.

## Sync engine

Robustness of the gossip sync engine, its Bluetooth transport, and failure
detection. Seeded from the deferred follow-ups of the 2026-07 audits
(shipped fixes are recorded in
[`audits/2026-07-06-algorithm-audit.md`](audits/2026-07-06-algorithm-audit.md) and
[`audits/2026-07-08-comprehensive-audit.md`](audits/2026-07-08-comprehensive-audit.md)).

- ☑ **High** — [One Bluetooth link per device pair in a mesh](backlog/engine-mesh-connection-tiebreak.md) · post-connect tie-break (smaller NodeId is central; loser closes its own central) — shipped in 5a6a764
- ☑ **Medium** — [Tell a rejected Bluetooth peer it was rejected](backlog/engine-reject-notify-capped-peers.md) · GSP2 control frame + receiver close + policy backoff — shipped in b210fdb..4f3d072; the WIRE4-9 subscribe race found by the 2026-08-20 audit was re-fixed in 3cf8445 (paced rejection re-sends triggered by inbound writes)
- ☐ **Medium** — [Remember that a view needs rebuilding, even across a crash](backlog/engine-materializer-rebuild-marker.md) · a failed or interrupted rebuild loses the rebuild-needed flag (memory only), so a later update resumes from the saved cursor and silently drops out-of-order entries; needs a materializer-contract change
- ☐ **Medium** — [Cut redundant work on the message hot path](backlog/engine-hot-path-performance.md) · type-byte dispatch before decode, encode-once-send-many, checkpointed rebuilds, cache the GATT characteristic
- ☐ **Medium** — [Per-peer send queues for the Nearby transport](backlog/engine-nearby-per-peer-queues.md) · one stalled endpoint currently head-of-line-blocks pings to every other peer; port the BLE transport's per-peer design
- ☐ **Low** — [Eliminate head-of-line blocking on the Bluetooth transport](backlog/engine-ble-frame-multiplexing.md) · an urgent message can still wait out one in-flight transfer; frame multiplexing would remove even that
- ☐ **Low** — [Correlate delta responses with the pulls that solicited them](backlog/engine-response-correlation.md) · "solicited" is matched per peer+stream, not per request, so a racing reactive push is misclassified as the pull's answer — misattributes the stall warning, the RTT sample, and (bounded, self-healing) stalled-range recording; true fix is a request id on the wire, dialect material
- ☐ **Low** — [Bound the Bluetooth send-queue depth](backlog/engine-send-queue-depth-cap.md) · add a size ceiling so a slow/stalled link can't grow the outgoing queue without limit (backstop; the congestion gate already throttles in practice)
- ☐ **Low** — [Revisit the failure-detection sensitivity thresholds](backlog/engine-swim-threshold-tuning.md) · measure and possibly tighten the 5/15 consecutive-miss thresholds now that fair-rotation probing and adaptive timeouts are in place — and re-measure once indirect checks are retired, since the thresholds were set with them
- ☐ **Low** — [Best-effort pre-connect identity hash in the Android advertisement](backlog/engine-preconnect-adv-hash.md) · skip initiating a losing mutual connect on Android↔Android pairs; post-connect tie-break stays the backstop
- ☐ **Medium** — [Send reactive pushes only to peers that share the data](backlog/engine-push-scoping.md) · scope push fan-out by channel membership + congestion-gate pushes and request bursts (2026-08 audit R6)
- ☐ **Medium** — [Only tell a peer about the groups you both belong to](backlog/engine-scope-digests-to-shared-groups.md) · digests advertise every channel a node holds, including its own user channel; measured on a mixed Android/iOS pair as 19 unusable channel ids × 22 rounds (~6.4 KB/exchange), and in the 2026-09-15 meeting as ~97 % of 710 KB out per phone per minute (the v48 meeting of 2026-09-17 measured ~300 KB per phone; digest share to be re-measured) — wasted airtime, log noise, and group/account ids disclosed to unrelated peers
- ☐ **Medium** — [Coalesce wire traffic into fewer radio wakeups](backlog/engine-message-coalescing.md) · SRTT-scaled debounce, batched deltas, push-pull completion, transport hold window (2026-08 audit R7)
- ☑ **High** — [Suppress pulling an author's range a peer has already failed to supply](backlog/engine-stalled-range-request-backoff.md) · per-author suppression with doubling re-probe backoff, per the [approved spec](superpowers/specs/2026-08-31-stalled-range-suppression-design.md) (pure-DDD shape: `StalledRangeRegistry` aggregate, strict command/query split) — merged 2026-09-01 as 7ebd076 (#15); the Kotlin port is in production since 2026-09-02. NOT the cause of the 2026-08-31 R14 incident: that was an uncapped JVM heap, and the loop ran 16 more times after that fix with no memory pressure
- ☐ **Low** — [Shrink version vectors on the wire with an author-index table](backlog/engine-author-index-wire-format.md) · wire-format change, both ends (2026-08 audit R8)
- ☐ **Low** — [Piggyback sync summaries on liveness probes](backlog/engine-digest-on-probe-piggyback.md) · one radio wakeup serves both loops; crosses the PeerDirectory seam with an opaque payload (WIRE4-19)
- ☐ **Low** — [Make Bluetooth advertising transmit power configurable](backlog/engine-ble-advertise-tx-power.md) · bluey hardcodes HIGH; add the knob upstream then plumb an owned enum like AdvertiseMode
- ☐ **Medium** — [Let transports declare their frame ceiling instead of the core assuming one](backlog/engine-transport-frame-capability.md) · optional maxFrameBytes capability on MessagePort (null = unbounded); core keeps maxMessageBytes as the mesh-wide contract but validates it against the local port and errors loudly on conflict
- ☐ **Medium** — [Reconnect the transport when a peer stops answering gossip while the link stays up](backlog/engine-reconnect-on-silent-peer.md) · a phone received nothing from the server for 63 minutes on 2026-09-16 while its socket answered keepalives; its own probes had gone unanswered the whole time — surface the detector's prolonged-unreachable verdict to the app so the server transport reconnects after a minute or two; defense in depth behind the v48 server fix, best taken after the Dart half of the relay retirement (owner, 2026-09-16); the server-side counterpart is the ping-timeout policy noted on the item (2026-09-17: eight timeouts on two phones, not worth retuning yet)

## Testing

Test-infrastructure quality: making simulated network conditions expressive
enough to exercise the failure modes the protocol logic exists for.

- ☑ **High** — [Simulate adverse network conditions in the test harness](backlog/testing-network-condition-simulation.md) · per-link drop/duplication/corruption/one-way-partition/held-latency policies, async delivery default, emergent backpressure — shipped in 4b0106f
- ☑ **High** — [Integration coverage for adverse network scenarios](backlog/testing-adverse-scenario-coverage.md) · 20 tests across loss/retry, asymmetric partition, duplicate frames, clock skew, congestion — shipped in 4b0106f
- ☑ **High** — [Run full syncs over a faulty BLE link in the end-to-end tests](backlog/testing-bluey-adverse-e2e.md) · chunk drop, hung write + send timeout, mid-message disconnect, supersession, connect backoff — shipped in c8c35ae
- ☑ **Medium** — [Cover the compaction state space with scenario tests](backlog/testing-compaction-scenario-coverage.md) · late-joiner lockout pin, transitive floors, returning peers, prune-all, per-author floors, mid-sync race — shipped in 94e515a..e9f055e with the OBS-3 rotation fix
- ☐ **Medium** — [A stateful fake network for the Nearby transport](backlog/testing-nearby-fake-port.md) · bring gossip_nearby up to bluey's standard: fake endpoint network + end-to-end Coordinator tests
- ☐ **Medium** — [Make the Bluetooth test fake faithful to real GATT behavior](backlog/testing-bluey-gatt-fidelity-fake.md) · subscription state + real 20 B write sizes first, then a fake beneath the platform adapter — the WIRE4-9 bug class is invisible to today's tests
- ☐ **Low** — [Quality-of-life additions to the adverse-network harness](backlog/testing-harness-niceties.md) · type-selective drop/duplicate predicates, per-node runRounds steps, duplicate-rate DSL wrapper, BLE facade test knobs
- ☐ **Low** — [Close the recorded test debt from the tie-break/rejection reviews](backlog/testing-tiebreak-followup-tests.md) · queued-send-across-swap, backoff dedup branch, both-orders stagger, codec edges, backoff-reset product decision

## Code health

Internal structure, documentation honesty, and audit-hygiene work — no
runtime behavior changes.

- ☑ **Medium** — [Realign the module layout and make the architecture scream](backlog/health-architecture-alignment.md) · concept-first bounded contexts (shared/sync/membership/coordinator) with a machine-checked boundary — part 1 shipped in 202bf6d..00420fc, part 2 shipped in 4024678..544efe8
- ☐ **Medium** — [Sweep the remaining minor audit findings](backlog/health-minor-findings-sweep.md) · two correctness latents (unbudgeted sync-request size, uncopied payload buffers) + transport minors + hygiene — Medium since 2026-09-16: sequenced behind the digest work in the current focus (owner)
- ☑ **High** — [Make the code read cleanly without its comment overlay](backlog/health-comment-hygiene.md) · strip audit-ID citations (substance inlined), delete history comments, extract commented paragraphs into named functions, retire banner dividers · shipped 2026-08-28, see the audit record's campaign-close section
- ☐ **Medium** — [Carry stack traces with reported errors](backlog/health-error-stack-traces.md) · SyncError has no stackTrace field, so live-path traces evaporate at the error boundary; add the field (additive) or route live errors through onLog
- ☐ **Low** — [Converge the transports' MessagePort close() semantics](backlog/health-transport-port-close-semantics.md) · nearby gates its own view only, bluey's close() tears down the whole connection layer — converge on port-gates-itself, facade owns teardown
- ☐ **Low** — [Give the sync engine its own sizing interface instead of downcasting its codec](backlog/health-sync-codec-sizing-port.md) · the injected `MessageCodec` gets cast to the concrete `SyncMessageCodec` for two byte-budget helpers; a sync-owned sizing interface would close the gap
- ☐ **Low** — [Normalize formatter drift so diffs stop lying](backlog/health-format-normalization.md) · one pinned-SDK formatting-only commit per package, then the format gate becomes a no-op
- ☐ **Medium** — [Reshape the runtime trackers into honest domain objects](backlog/health-pure-runtime-trackers.md) · stateful "domain services" that hold a clock and mutate inside queries are a recorded smell (owner ruling 2026-09-01); once the stalled-range aggregate sets the pure pattern, bring the pending-pull tracker and its siblings in line
- ☐ **Medium** — [Drop peer persistence from the Dart library](backlog/health-drop-peer-repository.md) · the library never reads it back (no restore path; findAll is documented as never called), the app never touches it, and the server already dropped its peers table — remove the interface, its write chain, and the constructor parameter, matching the Kotlin twin (owner ruling 2026-09-01)
- ☐ **Medium** — [Adopt the Kotlin twin's recorded improvements into the Dart library](backlog/health-adopt-kt-flow-backs.md) · the divergence register's "kt better" rows finally get a home: dispatch/decode seam, block-in-place partition healing, congestion test knob, clock escape hatch, compaction facades, test-strength idioms, plus the five Dart-side reshapes the Kotlin purification surfaced (news flag into the timing policy, a loop-generation collaborator, named gap/push registries, the never-heard-from freshness guard) — adopt or exempt, row by row

## Server

The deployed server (opendoor-api) as a node of the mesh: defects and
capabilities that live in its own repository but are sequenced by this
program because the fleet's health depends on them.

- ☑ **High** — [Stop the server from talking to a phone's dead session after it reconnects](backlog/server-session-ownership.md) · a reconnecting phone is unregistered by the old handler's cleanup; 267 sends to departed peers in the 2026-09-15 meeting, 193 from one phone that reconnected twelve times — the registered session is the owner, unregister-if-mine, register displaces, one two-sessions test; ships with the compaction fix (shipped in v48, 2026-09-16)
- ☑ **High** — [Let the server prune presence while a meeting is running](backlog/server-compaction-under-load.md) · every 5-minute compaction tick failed for three hours on 2026-09-15 (Postgres serialization collision with heartbeat inserts; 23 failures, table 2,970 → 39,989 rows, recovered in one pass after the room emptied) and each failure also escaped as an uncaught worker-thread exception — read-committed floor update, one delete per author, a transaction primitive that cannot cancel its caller (shipped in v48, 2026-09-16)
- ☐ **Medium** — [Stop the server reading a whole stream to answer a per-author question](backlog/server-entry-repository-full-stream-reads.md) · the batch append and the entries-since query each load the entire stream and filter in memory, ~150 times a minute in a meeting; push the predicates into SQL, and bound the transaction helper's IO dispatcher while there (final review of the meeting-fixes PR, 2026-09-16)
- ◐ **Medium** — [Measure how far behind the server's inbound queue runs at the peak of a meeting](backlog/server-inbound-merge-latency.md) · **implemented, live-device validated and merged 2026-09-17** (opendoor-api PR #24, real merge 7d7b279: `wait=<median>/<max>` on the health line, `lastMinuteWait` in `/admin/sync`; two phones in a waiting room read tens of milliseconds); released as Heroku v50 at 15:35 local the same day, `wait=` live on the production health line; done when the next meeting's read says whether the peak backlog is real · one observation from the 2026-09-17 meeting: at its busiest minute a just-disconnected phone drew replies for eleven more seconds, the shape of an eleven-second inbound backlog, past the app's 6 s presence freshness bound; add arrival-to-merge latency to the health line, then decide (owner agreed 2026-09-17)

## Kotlin port

Keeping the standalone Kotlin library (`gossip-kt`) current with what the
Dart library has learned since it was ported. The program's goal, exemption
register, and working conventions live in the
[twin parity program](parity.md); this track is its worklist.

- ◐ **High** — [Teach both libraries to speak versioned wire formats](backlog/kt-wire-versioning-campaign.md) · one-byte version marker, receive-both codecs, config-gated send (default legacy), shared conformance vectors — code and the receive-both deploys shipped 2026-08-31 (server + app, compaction support live end-to-end); the ordered send-side flips and translator retirement remain, gated on fleet coverage
- ◐ **High** — [Port the wire-efficiency behaviors to the Kotlin library](backlog/kt-port-wire-efficiency.md) · PHASE 1 MERGED 2026-09-02 (gossip-kt 0dafefd, real merge, suite 999): pacing both loops, reactive push, probe suppression + 2-min cap, scheduler migration, median-SRTT parity, isRunning scheduler-delegation — IN PRODUCTION 2026-09-02 (opendoor-api d89110a), live-device validated (~50× idle-cadence cut); phase 2 remains: recency suppression, dominance-filtered + request-scoped digest responses, DigestBudgeter
- ☑ **Low** — [Mirror the bounded-context structure in the Kotlin library](backlog/kt-mirror-bounded-contexts.md) · four evaluated divergences ported back + a Kotlin edge-table boundary test that now enforces the structure — shipped 2026-08-29 in gossip-kt 26dcc13..bd50285 (feature/compaction)
- ◐ **Medium** — [Audit the Kotlin library for the bug classes fixed in Dart](backlog/kt-audit-legacy-bug-classes.md) · audit done (13-item inventory); the storage-contract batch shipped in gossip-kt 1ffbf0d..3836bc7, the sync-path-depth batch (KT-B) shipped 2026-08-29 closing items 3/9/11, the remaining classes flow through the campaign's later batches
- ☑ **High** — [Retire indirect health probing from both libraries](backlog/kt-retire-indirect-probing.md) · **Kotlin half shipped** in gossip-kt ea0d51c (PR #8, 2026-09-15): the relay handler counts and ignores, the indirect phase is a grace window that races the late ack, Dart's ack-sender guard is ported; the Dart half remains · [ruled B, final](superpowers/specs/2026-09-01-swim-slimdown-decision.md) — the relay's purpose can't occur here (membership is local) and the Kotlin relay was inert in production anyway; Kotlin removes first inside the lifecycle batch (owner, 2026-09-14), the Dart half follows on this same item, PingReq becomes receive-only until the next dialect revision — replaces the former "make indirect probing work" defect item, closed by removal Dart rulings page drafted 2026-09-18 ([spec](superpowers/specs/2026-09-18-dart-relay-retirement-rulings.md)), awaiting owner review. **Dart half shipped 2026-09-18** (rulings page approved; ADR-004/012 amended, SWIM renamed away, grace-window race adopted). Both halves done; the app pin bump is item 8's tail.
- ☑ **High** — [Make stopping a Kotlin coordinator actually stop it](backlog/kt-coordinator-restart-lifecycle.md) · shipped in gossip-kt ea0d51c (PR #8, 2026-09-15, [rulings 1–12](superpowers/specs/2026-09-01-receive-loop-lifecycle-rulings.md)): the coordinator owns its collector (stop cancels it, pause keeps it, start joins a stale one then re-checks a lifecycle epoch), Dart's throwing preconditions and `resume()`, ingestion gated on the running flag, engines up before the collector attaches; the six withheld scenarios are the proof; suite 1046 → 1067
- ☑ **Medium** — [Stop the Kotlin library from treating cancellation as a failure](backlog/kt-cancellation-swallowed.md) · shipped in the same batch (gossip-kt ea0d51c): carve-outs at the five surviving suspend-carrying catch-alls, the append-and-notify pair runs non-cancellable so a stop mid-merge strands nothing, and the simulated clock cancels parked and late delays on close
- ☐ **Low** — [Sweep the remaining scenario coverage into the Kotlin library](backlog/kt-scenario-parity-sweep.md) · the harness and link-condition primitives now exist and ~66 scenarios are translated (the six lifecycle scenarios landed with gossip-kt ea0d51c); the scale and multi-channel groups plus two churn tests are mechanical follow-on; the relay scenario is obsolete
- ☑ **High** — [Port stalled-range suppression to the Kotlin library](backlog/kt-stalled-range-suppression-port.md) · merged 2026-09-02 as gossip-kt bbbf31f (#5, suite 938 → 959), reviewed line-for-line faithful — IN PRODUCTION 2026-09-02 via opendoor-api #17 (d89110a), live-device validated (floors adopted at first contact, zero stalls)
- ◐ **Medium** — [Record where the Dart library and its Kotlin twin diverge, with a verdict](backlog/kt-normalize-twin-divergences.md) · register active, growing a row per review; every row must end homed to a roadmap item, closed, or exempted in the parity program — the Dart-side adoptions now have a home in the flow-back sweep (Code health)
- ☑ **High** — [Purify the Kotlin domain layer: locks move to infrastructure wrappers](backlog/kt-pure-domain-concurrency.md) · every lock outside `infrastructure/` moved into `Synchronized*` wrappers (five domain services + four engine extractions + the pusher), machine-checked by `LockPlacementTest` (package-reference scan over comment-scrubbed source, exempt rows pin exact lines); the clock no longer suspends; the detector's ping-state extraction rode here (lifecycle ruling 2 superseded) — **merged 2026-09-02 as gossip-kt 26e5e24** (PR #7, real merge; suite 999 → 1046), per the [approved rulings](superpowers/specs/2026-09-02-kt-domain-purification-rulings.md); rides the next opendoor-api submodule bump
- ☐ **Low** — [Let the Kotlin application layer name only domain types](backlog/kt-application-types-against-domain.md) · purification left the engine, pusher, peer service, and detector importing their `Synchronized*` wrappers (application → infrastructure); extend the ruled subclass shape (open pure class, wrapper overrides every member, reflection pin) to them and add a layer-direction test, as opendoor-api did 2026-09-03 after the owner's audit of its sync-health change — priority proposed by the audit, owner to set
- ☐ **High** — [Give the Kotlin library the payload size cap the Dart library enforces](backlog/kt-payload-size-cap.md) · nothing kt-side refuses an oversized write and the server's frame limit is effectively infinite, so the server can create entries the phone fleet can never carry
- ☐ **High** — [Make stream access get-or-create in the Kotlin library](backlog/kt-get-or-create-stream.md) · the register calls this a real production issue: Dart quietly creates a missing stream on access, kt doesn't, and the kt harness works around it
- ☐ **Medium** — [Give the Kotlin library Dart's fair probe rotation and timing policies](backlog/kt-probe-selection-parity.md) · kt probes a random peer per round (an unlucky peer goes unchecked for long stretches); the structural half (a named `ProbeTargetSelector`) landed with purification (PR #7), so what remains is the shuffled-cursor behavior, the intermediary selection moving onto the selector, and the small helper adoptions
- ☐ **Medium** — [Make the timing-sensitive Kotlin tests immune to parallel load](backlog/kt-load-flaky-timing-tests.md) · three tests flake under full-suite load and pass in isolation: a reactive-push congestion test and an HLC causality test (purification batch, once each) and the unsolicited-push engine test (lifecycle batch, twice; six isolated runs clean) — the owner asked for this to be followed up first (2026-09-14)
- ☐ **Medium** — [Tidy the loose ends the lifecycle batch left in the Kotlin library](backlog/kt-lifecycle-batch-follow-ups.md) · the deferred reviewer findings from gossip-kt PR #8: compile-time guard for the restart guard's one-suspension promise (owner nod needed), engine test-harness teardown, simulated clock refusing late sleepers, the unreachable digest-answer gate pin, the mid-merge pin's ordering, stale comments and a duplicate contact record
- ☐ **Medium** — [Port the sync-activity snapshot API to the Kotlin library](backlog/kt-sync-activity-api.md) · Dart can answer "syncing or up to date?" (outstanding pulls, quiescence, merge counters); kt has no equivalent public surface
- ☑ **Medium** — [Move the Kotlin library's periodic loops onto the restartable scheduler](backlog/kt-periodic-loop-scheduler.md) · absorbed and closed by wire-efficiency phase 1 (gossip-kt #6): both loops now run per-cycle jittered delays on GenerationScheduler
- ☐ **Low** — [Share the ubiquitous-language glossary across the twins](backlog/kt-shared-glossary.md) · GLOSSARY.md exists only Dart-side with nothing kt-side pointing at it; single-source it and reconcile terms against the Kotlin names
- ☐ **Low** — [Certify twin parity with a closing audit](backlog/kt-final-parity-audit.md) · the migration's finish line — a fresh feature/structure/glossary/scenario/wire diff that certifies parity and leaves the exemption register as the complete, owner-ratified list of differences
