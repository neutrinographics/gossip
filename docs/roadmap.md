# Roadmap

The at-a-glance index of planned work. Each item links to a stand-alone
description in [`backlog/`](backlog/). **Priority and status live here only** —
never in a backlog file.

- **Status:** ☐ not started · ◐ in progress · ☑ done
- **Priority:** High · Medium · Low · Launch (gated to before public exposure)

## Current focus — deployed-fleet performance and stability (set 2026-09-01)

The campaign's aim right now is making the *deployed* server and phone fleet
faster and more stable, and the historical enemy is unnecessary wire
traffic. Work proceeds in this order (owner-set; full rationale in the
[retirement decision record](superpowers/specs/2026-09-01-swim-slimdown-decision.md)'s
review outcome and the parity program):

1. **Stop the measured waste** —
   [stalled-range suppression](backlog/engine-stalled-range-request-backoff.md)
   (Dart reference, spec in review) then
   [its Kotlin port](backlog/kt-stalled-range-suppression-port.md): the
   server re-ships hundreds of KB to every unupgraded phone, all day.
2. **Pace the server** — the
   [Kotlin wire-efficiency port](backlog/kt-port-wire-efficiency.md),
   quiescence pacing and probe suppression first: the server still talks at
   full cadence on every converged link (~30× more rounds than Dart).
3. **Flip the fleet to v2** when upgrade coverage allows (wire playbook
   steps 6–7; no dev work): v1's payload encoding costs ~3× the bytes of
   v2's on payload-heavy deltas.
4. **Stability hardening batch (Kotlin)** —
   [retire indirect probing](backlog/kt-retire-indirect-probing.md) (removes
   the server's 500 ms receive-loop stalls) + the
   [coordinator lifecycle fix](backlog/kt-coordinator-restart-lifecycle.md)
   + [cancellation](backlog/kt-cancellation-swallowed.md), one batch; plus
   the [payload cap](backlog/kt-payload-size-cap.md) and KT-E's
   entry-ordering fix.
5. **Then design the next traffic win** —
   [digest scoping to shared groups](backlog/engine-scope-digests-to-shared-groups.md)
   (spec first; every digest today advertises channels the peer doesn't share).

Kotlin work ships via opendoor-api submodule bumps — aim items 2 and 4 at
one bump, item 1's port plus KT-E at the next. Parity-completeness items
(probe-selection, sync-activity API, glossary, flow-backs, scenario sweep)
queue behind this push.

## Guardrails (design invariants)

Constraints that new work must respect (see `packages/gossip/docs/adr/`):

- **Single-isolate execution** — no locks; all engine state is touched from one isolate.
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
- ☐ **Low** — [Bound the Bluetooth send-queue depth](backlog/engine-send-queue-depth-cap.md) · add a size ceiling so a slow/stalled link can't grow the outgoing queue without limit (backstop; the congestion gate already throttles in practice)
- ☐ **Low** — [Revisit the failure-detection sensitivity thresholds](backlog/engine-swim-threshold-tuning.md) · measure and possibly tighten the 5/15 consecutive-miss thresholds now that fair-rotation probing, adaptive timeouts, and indirect checks are in place
- ☐ **Low** — [Best-effort pre-connect identity hash in the Android advertisement](backlog/engine-preconnect-adv-hash.md) · skip initiating a losing mutual connect on Android↔Android pairs; post-connect tie-break stays the backstop
- ☐ **Medium** — [Send reactive pushes only to peers that share the data](backlog/engine-push-scoping.md) · scope push fan-out by channel membership + congestion-gate pushes and request bursts (2026-08 audit R6)
- ☐ **Medium** — [Only tell a peer about the groups you both belong to](backlog/engine-scope-digests-to-shared-groups.md) · digests advertise every channel a node holds, including its own user channel; measured on a mixed Android/iOS pair as 19 unusable channel ids × 22 rounds (~6.4 KB/exchange) — wasted airtime, log noise, and group/account ids disclosed to unrelated peers
- ☐ **Medium** — [Coalesce wire traffic into fewer radio wakeups](backlog/engine-message-coalescing.md) · SRTT-scaled debounce, batched deltas, push-pull completion, transport hold window (2026-08 audit R7)
- ◐ **High** — [Suppress pulling an author's range a peer has already failed to supply](backlog/engine-stalled-range-request-backoff.md) · a sequence-hole response is refused but the range is re-shipped on every later exchange forever (measured: 2041 entries / 765 KB re-sent 59 times in minutes); per-author suppression with re-probe backoff — [spec approved 2026-09-01](superpowers/specs/2026-08-31-stalled-range-suppression-design.md) with the owner's pure-DDD reshape folded in (aggregate + strict command/query split); ready for a plan. NOT the cause of the 2026-08-31 R14 incident despite an earlier claim: that was an uncapped JVM heap on a Docker deploy, and the loop ran 16 more times after the fix with no memory pressure
- ☐ **Low** — [Shrink version vectors on the wire with an author-index table](backlog/engine-author-index-wire-format.md) · wire-format change, both ends (2026-08 audit R8)
- ☐ **Low** — [Piggyback sync summaries on liveness probes](backlog/engine-digest-on-probe-piggyback.md) · one radio wakeup serves both loops; crosses the PeerDirectory seam with an opaque payload (WIRE4-19)
- ☐ **Low** — [Make Bluetooth advertising transmit power configurable](backlog/engine-ble-advertise-tx-power.md) · bluey hardcodes HIGH; add the knob upstream then plumb an owned enum like AdvertiseMode
- ☐ **Medium** — [Let transports declare their frame ceiling instead of the core assuming one](backlog/engine-transport-frame-capability.md) · optional maxFrameBytes capability on MessagePort (null = unbounded); core keeps maxMessageBytes as the mesh-wide contract but validates it against the local port and errors loudly on conflict

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
- ☐ **High** — [Sweep the remaining minor audit findings](backlog/health-minor-findings-sweep.md) · two correctness latents (unbudgeted sync-request size, uncopied payload buffers) + transport minors + hygiene
- ☑ **High** — [Make the code read cleanly without its comment overlay](backlog/health-comment-hygiene.md) · strip audit-ID citations (substance inlined), delete history comments, extract commented paragraphs into named functions, retire banner dividers · shipped 2026-08-28, see the audit record's campaign-close section
- ☐ **Medium** — [Carry stack traces with reported errors](backlog/health-error-stack-traces.md) · SyncError has no stackTrace field, so live-path traces evaporate at the error boundary; add the field (additive) or route live errors through onLog
- ☐ **Low** — [Converge the transports' MessagePort close() semantics](backlog/health-transport-port-close-semantics.md) · nearby gates its own view only, bluey's close() tears down the whole connection layer — converge on port-gates-itself, facade owns teardown
- ☐ **Low** — [Give the sync engine its own sizing interface instead of downcasting its codec](backlog/health-sync-codec-sizing-port.md) · the injected `MessageCodec` gets cast to the concrete `SyncMessageCodec` for two byte-budget helpers; a sync-owned sizing interface would close the gap
- ☐ **Low** — [Normalize formatter drift so diffs stop lying](backlog/health-format-normalization.md) · one pinned-SDK formatting-only commit per package, then the format gate becomes a no-op
- ☐ **Medium** — [Reshape the runtime trackers into honest domain objects](backlog/health-pure-runtime-trackers.md) · stateful "domain services" that hold a clock and mutate inside queries are a recorded smell (owner ruling 2026-09-01); once the stalled-range aggregate sets the pure pattern, bring the pending-pull tracker and its siblings in line
- ☐ **Medium** — [Drop peer persistence from the Dart library](backlog/health-drop-peer-repository.md) · the library never reads it back (no restore path; findAll is documented as never called), the app never touches it, and the server already dropped its peers table — remove the interface, its write chain, and the constructor parameter, matching the Kotlin twin (owner ruling 2026-09-01)
- ☐ **Medium** — [Adopt the Kotlin twin's recorded improvements into the Dart library](backlog/health-adopt-kt-flow-backs.md) · the divergence register's "kt better" rows finally get a home: dispatch/decode seam, block-in-place partition healing, congestion test knob, clock escape hatch, compaction facades, test-strength idioms — adopt or exempt, row by row

## Kotlin port

Keeping the standalone Kotlin library (`gossip-kt`) current with what the
Dart library has learned since it was ported. The program's goal, exemption
register, and working conventions live in the
[twin parity program](parity.md); this track is its worklist.

- ◐ **High** — [Teach both libraries to speak versioned wire formats](backlog/kt-wire-versioning-campaign.md) · one-byte version marker, receive-both codecs, config-gated send (default legacy), shared conformance vectors — code and the receive-both deploys shipped 2026-08-31 (server + app, compaction support live end-to-end); the ordered send-side flips and translator retirement remain, gated on fleet coverage
- ☐ **High** — [Port the wire-efficiency behaviors to the Kotlin library](backlog/kt-port-wire-efficiency.md) · quiescence pacing and probe suppression FIRST (the server talks at full cadence on every converged link — ~30× the rounds), dominance filter and recency next; unblocked now that the wire format shipped; raised Medium → High 2026-09-01 for the deployed-fleet push
- ☑ **Low** — [Mirror the bounded-context structure in the Kotlin library](backlog/kt-mirror-bounded-contexts.md) · four evaluated divergences ported back + a Kotlin edge-table boundary test that now enforces the structure — shipped 2026-08-29 in gossip-kt 26dcc13..bd50285 (feature/compaction)
- ◐ **Medium** — [Audit the Kotlin library for the bug classes fixed in Dart](backlog/kt-audit-legacy-bug-classes.md) · audit done (13-item inventory); the storage-contract batch shipped in gossip-kt 1ffbf0d..3836bc7, the sync-path-depth batch (KT-B) shipped 2026-08-29 closing items 3/9/11, the remaining classes flow through the campaign's later batches
- ☐ **High** — [Retire indirect health probing from both libraries](backlog/kt-retire-indirect-probing.md) · [ruled B, final](superpowers/specs/2026-09-01-swim-slimdown-decision.md) — the relay's purpose can't occur here (membership is local) and the Kotlin relay was inert in production anyway; Dart removes first, the Kotlin half rides the lifecycle batch, PingReq becomes receive-only until the next dialect revision — replaces the former "make indirect probing work" defect item, closed by removal
- ◐ **High** — [Make stopping a Kotlin coordinator actually stop it](backlog/kt-coordinator-restart-lifecycle.md) · stop never cancels the message listener and nothing gates ingestion on running, so a stopped node keeps merging peer data and each restart stacks another listener into duplicate-write failures — same batch, same rulings page
- ◐ **Medium** — [Stop the Kotlin library from treating cancellation as a failure](backlog/kt-cancellation-swallowed.md) · nine catch-alls (six recorded + three found at spec time) swallow the coroutine cancellation signal — folded into the coordinator-lifecycle batch, which restructures the same sites
- ☐ **Low** — [Sweep the remaining scenario coverage into the Kotlin library](backlog/kt-scenario-parity-sweep.md) · the harness and link-condition primitives now exist and ~60 scenarios are translated; the scale, multi-channel, and remaining edge/lifecycle groups are mechanical follow-on
- ☐ **High** — [Port stalled-range suppression to the Kotlin library](backlog/kt-stalled-range-suppression-port.md) · translate the Dart reference once it lands; the server is the node pairing with every unupgraded phone, so it feels the mixed-fleet waste first — ships via opendoor-api submodule bump
- ◐ **Medium** — [Record where the Dart library and its Kotlin twin diverge, with a verdict](backlog/kt-normalize-twin-divergences.md) · register active, growing a row per review; every row must end homed to a roadmap item, closed, or exempted in the parity program — the Dart-side adoptions now have a home in the flow-back sweep (Code health)
- ☐ **High** — [Give the Kotlin library the payload size cap the Dart library enforces](backlog/kt-payload-size-cap.md) · nothing kt-side refuses an oversized write and the server's frame limit is effectively infinite, so the server can create entries the phone fleet can never carry
- ☐ **High** — [Make stream access get-or-create in the Kotlin library](backlog/kt-get-or-create-stream.md) · the register calls this a real production issue: Dart quietly creates a missing stream on access, kt doesn't, and the kt harness works around it
- ☐ **Medium** — [Give the Kotlin library Dart's fair probe rotation and timing policies](backlog/kt-probe-selection-parity.md) · kt probes a random peer per round (an unlucky peer goes unchecked for long stretches) and inlines the timing rules Dart keeps in named policy objects
- ☐ **Medium** — [Port the sync-activity snapshot API to the Kotlin library](backlog/kt-sync-activity-api.md) · Dart can answer "syncing or up to date?" (outstanding pulls, quiescence, merge counters); kt has no equivalent public surface
- ☐ **Medium** — [Move the Kotlin library's periodic loops onto the restartable scheduler](backlog/kt-periodic-loop-scheduler.md) · gossip and probe loops freeze their adaptive interval at start; only the compaction loop uses the per-cycle scheduler kt already ported
- ☐ **Low** — [Share the ubiquitous-language glossary across the twins](backlog/kt-shared-glossary.md) · GLOSSARY.md exists only Dart-side with nothing kt-side pointing at it; single-source it and reconcile terms against the Kotlin names
- ☐ **Low** — [Certify twin parity with a closing audit](backlog/kt-final-parity-audit.md) · the migration's finish line — a fresh feature/structure/glossary/scenario/wire diff that certifies parity and leaves the exemption register as the complete, owner-ratified list of differences
