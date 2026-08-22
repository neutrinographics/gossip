# Bounded Contexts Restructure (Batch 3, Part 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure `packages/gossip` from layer-first to concept-first — `shared/ sync/ membership/ coordinator/` with `domain/application/infrastructure` interiors — with the boundary rule machine-enforced, per-context codecs and event families, and the sync↔membership contract behind a sync-owned port.

**Architecture:** Seams first, moves second. Tasks 1-4 introduce the new seams (per-context sealed event families, per-context codecs behind a shared `MessageCodec` interface, `PeerDirectory` + ACL) as small reviewable diffs in the current tree, creating new files at their FINAL paths. Tasks 5-8 are then purely mechanical module moves under a green gate, ending with the edge-table boundary test. Task 9 is docs.

**Tech Stack:** Pure Dart, `packages/gossip` only (transports consume the barrel and are untouched; Task 8 re-verifies them).

**Spec:** `docs/superpowers/specs/2026-08-21-bounded-contexts-restructure-design.md`

## Global Constraints

- Work directly on `working-connection` (repo precedent; no worktree).
- **Boundary rule (owner decision, binding):** a context imports `shared/` and itself only; a context's `infrastructure/` may import another context solely to implement an interface its own domain defines. No other exception exists. `MembershipPeerDirectory` is the only intended concession.
- **Taxonomy (binding):** domain subfolders name KINDS — `aggregates/ entities/ value_objects/ services/ interfaces/ events/ errors/ messages/`. No `values/`, no `results/` (operation results are value objects). `messages/` is the one role-named exception (published-language seam).
- **Public API frozen:** `lib/gossip.dart` keeps the identical exported SYMBOLS (42 export lines' worth) — paths inside `src/` change, names do not. The transports compile untouched.
- **Wire format frozen:** type bytes 0=Ping 1=Ack 2=PingReq (membership), 3=DigestRequest 4=DigestResponse 5=DeltaRequest 6=DeltaResponse (sync); encode/decode logic moves VERBATIM — splitting the codec must not change a single wire byte.
- Strict TDD for new seams (wire-types partition test, codec split, `PeerDirectory`); module moves are behavior-neutral — the suite is the net, gates green after every task: `cd packages/gossip && dart test && dart analyze`. Task 8 adds the full monorepo (`melos run test && melos run analyze`).
- Never weaken an existing assertion. Move-verbatim instructions mean MOVE the code, do not re-derive it.
- Commit style `refactor(gossip): …` / `feat(gossip): …` / `test(gossip): …` / `docs: …`, each commit ending with:

```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

---

### Task 1: Per-context sealed event families

**Files:**
- Create: `packages/gossip/lib/src/sync/domain/events/sync_events.dart`
- Create: `packages/gossip/lib/src/membership/domain/events/membership_events.dart`
- Modify: `packages/gossip/lib/src/domain/events/domain_event.dart` (shrinks to the abstract base + `SyncErrorOccurred`)
- Modify: `packages/gossip/lib/gossip.dart` (barrel: add exports of the two new files — same public symbols, new homes)
- Modify: every producer/test that names a moved event class (imports only)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `sealed class SyncEvent extends DomainEvent` containing (moved VERBATIM from domain_event.dart): `ChannelCreated, ChannelRemoved, MemberAdded, MemberRemoved, StreamCreated, EntryAppended, EntriesMerged, StreamCompacted, BufferOverflowOccurred, NonMemberEntriesRejected`. `sealed class MembershipEvent extends DomainEvent` containing: `PeerAdded, PeerRemoved, PeerStatusChanged, PeerOperationSkipped`. `DomainEvent` becomes plain `abstract class` (no longer `sealed`); `SyncErrorOccurred` stays beside the base (it wraps the shared `SyncError` and has no context-specific emitter — verified 2026-08-22: only sync_error.dart and domain_event.dart reference it).

**Verified fact:** no production or test code switches exhaustively over `DomainEvent` (grep for `switch (.*[Ee]vent` across lib+test, 2026-08-22: zero hits) — un-sealing the base breaks nothing.

- [ ] **Step 1: Write the failing seam test**

```dart
// packages/gossip/test/domain/events/event_families_test.dart
import 'package:test/test.dart';
import 'package:gossip/gossip.dart';

/// Part 2 spec: per-context sealed families under an abstract shared base.
void main() {
  test('sync events are SyncEvents; membership events are MembershipEvents',
      () {
    expect(
      ChannelCreated(channelId: ChannelId('c'), creator: NodeId('n')),
      isA<SyncEvent>(),
    );
    expect(PeerAdded(NodeId('n')), isA<MembershipEvent>());
    // Both families still share the base — consumers of the public
    // Stream<DomainEvent> are unaffected.
    expect(PeerAdded(NodeId('n')), isA<DomainEvent>());
  });
}
```

(Mirror each event's REAL constructor — read domain_event.dart before writing; the `isA<...>` assertions are the contract. `SyncEvent`/`MembershipEvent` must be exported for this to compile — that is part of the RED.)

Run: `dart test test/domain/events/event_families_test.dart`
Expected: FAIL — `SyncEvent`/`MembershipEvent` don't exist.

- [ ] **Step 2: Implement**

1. Create the two new files. Each declares its sealed family root (`sealed class SyncEvent extends DomainEvent { const SyncEvent(); }`, same for `MembershipEvent`) and holds its event classes moved VERBATIM from domain_event.dart, with only the `extends` clause changed from `DomainEvent` to the family root. Preserve every doc comment.
2. domain_event.dart keeps: the (now `abstract`, not `sealed`) `DomainEvent` base and `SyncErrorOccurred` unchanged.
3. Barrel: add `export 'src/sync/domain/events/sync_events.dart';` and `export 'src/membership/domain/events/membership_events.dart';` beside the existing domain_event export.
4. Fix imports at every site that names a moved class (producers: channel_aggregate.dart, peer_registry.dart, peer.dart, engines, services; plus tests). Prefer adding the specific new import; the barrel keeps external consumers whole.

- [ ] **Step 3: Verify green + gates**

Run: `dart test test/domain/events/event_families_test.dart` → PASS, then `dart test && dart analyze` → all green, zero.

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(gossip): per-context sealed event families under an abstract DomainEvent base"
```

---

### Task 2: wire_types + MessageCodec interface + per-context codecs

**Files:**
- Create: `packages/gossip/lib/src/shared/domain/value_objects/wire_types.dart`
- Create: `packages/gossip/lib/src/shared/domain/interfaces/message_codec.dart`
- Create: `packages/gossip/lib/src/sync/infrastructure/sync_message_codec.dart`
- Create: `packages/gossip/lib/src/membership/infrastructure/membership_message_codec.dart`
- Modify: `packages/gossip/lib/src/protocol/protocol_codec.dart` (becomes a thin composite of the two — see Step 3.4)
- Test: `packages/gossip/test/shared/domain/value_objects/wire_types_test.dart` (new), plus the existing codec tests stay green unchanged

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces (Tasks 3+ rely on these exactly):

```dart
// wire_types.dart — the envelope agreement both codecs obey. Pure constants.
/// Wire type-byte partition (Part 2 spec). Membership owns 0-2, sync owns
/// 3-6. The partition test asserts no overlap; changing an existing value
/// is a wire-format break and is forbidden.
abstract final class WireTypes {
  static const int ping = 0;
  static const int ack = 1;
  static const int pingReq = 2;
  static const int digestRequest = 3;
  static const int digestResponse = 4;
  static const int deltaRequest = 5;
  static const int deltaResponse = 6;

  static const Set<int> membership = {ping, ack, pingReq};
  static const Set<int> sync =
      {digestRequest, digestResponse, deltaRequest, deltaResponse};
}
```

```dart
// message_codec.dart
import 'dart:typed_data';
import '../../../protocol/messages/protocol_message.dart'; // path updated in Task 5's move

/// Wire codec seam (Part 2 spec): each context implements this for its OWN
/// message family and answers null for foreign type bytes.
abstract interface class MessageCodec {
  Uint8List encode(ProtocolMessage message);

  /// Returns null when [bytes] carries a type byte outside this codec's
  /// family ("not mine"); throws only on genuinely malformed frames of its
  /// own family (preserving ProtocolCodec's current error behavior).
  ProtocolMessage? decode(Uint8List bytes);
}
```

- `SyncMessageCodec implements MessageCodec` — encode/decode for types 3-6, logic moved VERBATIM from `ProtocolCodec`, plus the static `maxEntryPayloadForBudget` helper (moved with it; entries are a sync concern). `MembershipMessageCodec implements MessageCodec` — types 0-2, moved verbatim. Both consult `WireTypes` instead of private `_type*` constants.

- [ ] **Step 1: Failing partition test**

```dart
// test/shared/domain/value_objects/wire_types_test.dart
import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_types.dart';

void main() {
  test('the type-byte partition has no overlaps and covers 0-6', () {
    expect(WireTypes.membership.intersection(WireTypes.sync), isEmpty);
    expect(
      WireTypes.membership.union(WireTypes.sync),
      {0, 1, 2, 3, 4, 5, 6},
    );
  });
}
```

Run → FAIL (file doesn't exist). Implement wire_types.dart → PASS.

- [ ] **Step 2: Failing codec-split test**

```dart
// append to an appropriate new file: test/sync/infrastructure/sync_message_codec_test.dart
// and test/membership/infrastructure/membership_message_codec_test.dart
// Contract per codec (write BOTH, watch both fail):
//  1. round-trips every message type of its own family byte-identically
//     with ProtocolCodec (encode with the context codec, decode with
//     ProtocolCodec, and vice versa — the wire-freeze proof);
//  2. decode() returns null for a frame of the OTHER family;
//  3. decode() preserves ProtocolCodec's current malformed-frame error
//     behavior for its own family.
// Build message fixtures by mirroring the existing protocol_codec tests
// (test/protocol/*codec*): their construction helpers are the source of
// truth for realistic message instances.
```

Run → FAIL (codec files don't exist).

- [ ] **Step 3: Implement the split (move-verbatim)**

1. Create both context codecs; MOVE each message type's encode/decode branches verbatim out of `ProtocolCodec` (JSON shape, field order, base64 handling — untouched). Replace `_type*` constants with `WireTypes.*`.
2. Each codec's `decode` first reads the type byte exactly where `ProtocolCodec` does; if it belongs to the other family, return null; else proceed with the moved logic.
3. `maxEntryPayloadForBudget` (and its `_entryEnvelopeOverhead`) move to `SyncMessageCodec`; `Coordinator`'s call site updates.
4. `ProtocolCodec` itself becomes a thin composite delegating to the two context codecs (`decode` tries membership then sync — or dispatches on the type byte via `WireTypes`; `encode` dispatches on message type). Its public behavior is unchanged, so every existing codec test stays green UNMODIFIED — that is the regression proof. (Task 3 moves the engines onto the interface; Task 7 deletes the composite once nothing uses it — see that task.)

Run: both new codec tests PASS; `dart test && dart analyze` → all green, zero (existing codec tests untouched and green).

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(gossip): per-context wire codecs behind a shared MessageCodec seam (wire format frozen)"
```

---

### Task 3: Engines take their context codec by injection

**Files:**
- Modify: `packages/gossip/lib/src/protocol/gossip_engine.dart` (field `final ProtocolCodec _codec = ProtocolCodec();` at ~140 → injected `MessageCodec`)
- Modify: `packages/gossip/lib/src/protocol/failure_detector.dart` (same at ~114)
- Modify: `packages/gossip/lib/src/facade/coordinator.dart` (constructs `SyncMessageCodec()` for the engine, `MembershipMessageCodec()` for the detector)
- Modify: `packages/gossip/test/protocol/gossip_engine_test_harness.dart`, `failure_detector_test_harness.dart`, and any test constructing an engine directly (constructor gains the codec argument)

**Interfaces:**
- Consumes: `MessageCodec`, `SyncMessageCodec`, `MembershipMessageCodec` from Task 2.
- Produces: `GossipEngine({..., required MessageCodec codec, ...})`, `FailureDetector({..., required MessageCodec codec, ...})` — Task 4's harness edits assume these names.

- [ ] **Step 1: Failing test**

Add to `test/protocol/gossip_engine_pacing_test.dart`'s file-level group (or a small new `test/protocol/engine_codec_injection_test.dart`): construct the harness engine, deliver a MEMBERSHIP frame (encode a Ping via `MembershipMessageCodec`) onto the engine's port, and assert the engine ignores it without error (no thrown decode error; no state change); mirror with a sync frame at the detector. RED first: with the inline `ProtocolCodec()` still in place this passes trivially — so the honest RED is the CONSTRUCTOR change: write the test to construct `GossipEngine(codec: SyncMessageCodec(), ...)` explicitly; it fails to compile until the parameter exists. Watch it fail for that reason.

- [ ] **Step 2: Implement**

Swap the inline fields for injected `MessageCodec` constructor params (required, no default — every construction site updates); engines' decode paths already ignore messages that decode to types they don't handle; now a foreign-family frame decodes to null — add the one-line null-check-and-return where each engine decodes (preserving today's "ignore what isn't mine" behavior; the engine must not log an error for a healthy foreign frame). Coordinator wires the two context codecs. Harnesses pass `SyncMessageCodec()` / `MembershipMessageCodec()`.

- [ ] **Step 3: Gates**

`dart test && dart analyze` → all green, zero.

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(gossip): engines take their context codec via MessageCodec injection"
```

---

### Task 4: PeerDirectory port + SyncPartner + MembershipPeerDirectory ACL

**Files:**
- Create: `packages/gossip/lib/src/sync/domain/interfaces/peer_directory.dart`
- Create: `packages/gossip/lib/src/sync/domain/value_objects/sync_partner.dart`
- Create: `packages/gossip/lib/src/sync/infrastructure/membership_peer_directory.dart`
- Modify: `packages/gossip/lib/src/protocol/gossip_engine.dart` (field `peerRegistry` → `PeerDirectory`; all six call sites)
- Modify: `packages/gossip/lib/src/facade/coordinator.dart` (wires `MembershipPeerDirectory(peerRegistry)` into the engine)
- Modify: `packages/gossip/test/protocol/gossip_engine_test_harness.dart` + direct-construction tests (wire the ACL over the existing registry — tests keep driving the registry directly; the ACL forwards)
- Test: `packages/gossip/test/sync/infrastructure/membership_peer_directory_test.dart` (new)

**Interfaces:**
- Consumes: nothing new.
- Produces (verified against the engine's REAL registry surface, 2026-08-22 — six operations):

```dart
// sync/domain/value_objects/sync_partner.dart
import '../../../domain/value_objects/node_id.dart';   // paths updated by Task 5's move

/// Sync's own view of a gossip partner (Part 2 spec) — deliberately NOT
/// membership's Peer. Carries exactly what partner selection and pacing
/// read.
class SyncPartner {
  const SyncPartner({
    required this.nodeId,
    this.smoothedRtt,
    this.lastAntiEntropyMs,
  });

  final NodeId nodeId;
  final Duration? smoothedRtt;      // median-SRTT base interval input
  final int? lastAntiEntropyMs;     // recency-suppression input
}
```

```dart
// sync/domain/interfaces/peer_directory.dart
/// Sync's port onto peer state (Part 2 spec): THE sync↔membership
/// contract. Implemented by an ACL in sync/infrastructure — the boundary
/// rule's only concession. WIRE4-19 piggybacking later extends this port.
abstract interface class PeerDirectory {
  List<SyncPartner> reachablePartners();
  SyncPartner? selectRandomPartner();      // mirrors selectRandomReachablePeer semantics
  void recordContact(NodeId peer, int nowMs);
  void recordMessageReceived(NodeId peer, int bytes, int nowMs, int windowMs);
  void recordMessageSent(NodeId peer, int bytes);
  void recordAntiEntropy(NodeId peer, int nowMs);
}
```

(Signature adaptation rule: each method mirrors the EXACT parameter list of the registry method the engine calls today — read the six call sites first; the sketch's parameter lists yield to reality. `selectRandomPartner` must preserve the registry's selection semantics — delegate, don't reimplement.)

- `MembershipPeerDirectory implements PeerDirectory` in `sync/infrastructure/` — the ACL: wraps `PeerRegistry`, forwards each call, maps `Peer` → `SyncPartner` (`smoothedRtt` from `peer.metrics.rttEstimate?.smoothedRtt`, `lastAntiEntropyMs` from the peer). This file is the ONLY sync file importing membership types.

- [ ] **Step 1: Failing ACL test**

```dart
// test/sync/infrastructure/membership_peer_directory_test.dart — contract:
//  1. reachablePartners() mirrors registry.reachablePeers (ids, rtt,
//     lastAntiEntropyMs mapped correctly, including nulls);
//  2. each record* forwards to the registry (observable via the registry's
//     own state afterward — no mocks; use a real PeerRegistry);
//  3. selectRandomPartner() returns a partner the registry would select
//     (seeded/deterministic per the registry's existing behavior).
```

Write it against a real `PeerRegistry` (construct, add peers, drive) — RED: files don't exist.

- [ ] **Step 2: Implement the three new files; ACL test green**

- [ ] **Step 3: Rewire the engine**

`GossipEngine`'s `peerRegistry` field/constructor param becomes `PeerDirectory peerDirectory` (update the six call sites: `reachablePeers`→`reachablePartners`, `selectRandomReachablePeer`→`selectRandomPartner`, `updatePeerContact`→`recordContact`, `updatePeerAntiEntropy`→`recordAntiEntropy`, `recordMessageReceived`/`recordMessageSent`→same names; the candidate filter reads `partner.lastAntiEntropyMs`; `_adaptiveBaseInterval` reads `partner.smoothedRtt`). The engine must no longer import `peer_registry.dart` or `peer.dart` — verify with grep. Coordinator wires the ACL. Harnesses wrap their registry in `MembershipPeerDirectory` when constructing the engine (tests keep manipulating the registry; assertions unchanged).

- [ ] **Step 4: Gates**

`dart test && dart analyze` → all green, zero. Then:
```bash
grep -n "peer_registry\|entities/peer.dart" packages/gossip/lib/src/protocol/gossip_engine.dart
```
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(gossip): PeerDirectory port + MembershipPeerDirectory ACL — the sync↔membership contract"
```

---

### Task 5: Mechanical move — shared/

**Files:** per the spec's shared/ mapping table (value_objects incl. log_level + wire_types already in place; errors; events base file; services jitter/quiescence_pacer/rtt_tracker/time_source; interfaces time_port/message_port/local_node_repository/message_codec already in place/protocol_message; infrastructure real_time_port/in_memory_time_port/in_memory_message_port/in_memory_local_node_repository). Tests mirror to `test/shared/`.

- [ ] **Step 1: Normalize intra-package imports to package: form**

Write and run a one-off script (commit it under `tool/normalize_imports.py`) that rewrites every RELATIVE import/export between files under `lib/src/` into the absolute `package:gossip/src/...` form, across lib and test. This makes every subsequent move a pure string substitution (no relative-path math). Gate: `dart test && dart analyze` green/zero — behavior-neutral. Commit separately: `refactor(gossip): normalize intra-package imports to package form`.

- [ ] **Step 2: Move the shared/ files**

`git mv` each file per the spec table (e.g. `lib/src/domain/value_objects/node_id.dart` → `lib/src/shared/domain/value_objects/node_id.dart`; `lib/src/infrastructure/ports/time_port.dart` → `lib/src/shared/domain/interfaces/time_port.dart`; implementations → `lib/src/shared/infrastructure/`; `lib/src/protocol/messages/protocol_message.dart` → `lib/src/shared/domain/interfaces/protocol_message.dart`). Then run a path-rewrite script (extend the same tool): map each old `package:gossip/src/<old>` to `package:gossip/src/<new>` across lib, test, and the barrel. Mirror the test files (`git mv test/domain/value_objects/... test/shared/domain/value_objects/...` etc. — a test moves when its subject moved).

- [ ] **Step 3: Gates + barrel check**

`dart test && dart analyze` green/zero. `cd ../gossip_bluey && flutter test` (spot-check one transport compiles against the barrel — full monorepo waits for Task 8).

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(gossip): shared kernel — move identity/causality VOs, errors, events base, shared services, ports"
```

---

### Task 6: Mechanical move — membership/

Same method as Task 5 Step 2 (the normalize script already ran): move per the spec's membership/ table — `peer_registry` → `membership/domain/aggregates/`, `peer`/`peer_metrics` → `membership/domain/entities/`, `ping`/`ack`/`ping_req` → `membership/domain/messages/`, `peer_repository` → `membership/domain/interfaces/`, `peer_service`/`failure_detector` → `membership/application/`, `in_memory_peer_repository`/`membership_message_codec` (created in Task 2 at the right home — verify, don't re-move) → `membership/infrastructure/`. Tests mirror to `test/membership/` (the detector tests + harness move here from `test/protocol/`).

Gate `dart test && dart analyze` green/zero. Commit:
```bash
git commit -m "refactor(gossip): membership context — peers model + SWIM detector move home"
```

---

### Task 7: Mechanical move — sync/ (+ delete the composite codec)

Move per the spec's sync/ table: `channel_aggregate` → `sync/domain/aggregates/`, `stream_config` → `sync/domain/entities/`, `channel_digest`/`stream_digest`/`merge_result`/`channel_delta`/`compaction_result` → `sync/domain/value_objects/`, `hlc_clock` → `sync/domain/services/`, digest/delta messages → `sync/domain/messages/`, repo/materializer/retention interfaces + `peer_directory` (already home) → `sync/domain/interfaces/`, `channel_service`/`gossip_engine` → `sync/application/` (+ `materialization/` subfolder for materialization_service, fold_cursor, materializer_state), repos + entry store + `sync_message_codec` + `membership_peer_directory` (already home) → `sync/infrastructure/`. Tests mirror to `test/sync/` (engine tests + harness move from `test/protocol/`; integration/support suites stay put with imports rewritten).

Then DELETE `lib/src/protocol/protocol_codec.dart` (the Task-2 composite): first `grep -rn "ProtocolCodec" lib test` — remaining consumers should be only its own tests; convert those tests to drive the two context codecs directly (the round-trip cross-checks from Task 2 already cover the wire; keep every wire-shape assertion by retargeting it at the owning context codec — never delete an assertion). Remove the now-empty `lib/src/protocol/` and `lib/src/domain/`, `lib/src/application/`, `lib/src/infrastructure/` directories (everything must have a new home; `find lib/src -type d -empty` shows stragglers).

Gate `dart test && dart analyze` green/zero. Commit:
```bash
git commit -m "refactor(gossip): sync context — replicated-log model, engine, materialization move home; composite codec retired"
```

---

### Task 8: coordinator/ move, context barrels, boundary edge-table test, full gates

**Files:**
- Move: the nine `facade/` files → `lib/src/coordinator/` (flat, per spec); `test/facade/` → `test/coordinator/`
- Create: `lib/src/shared/shared.dart`, `lib/src/sync/sync.dart`, `lib/src/membership/membership.dart` (context barrels naming each module's public surface; `coordinator/` imports through them where practical)
- Modify: `lib/gossip.dart` (final export-path sweep; SYMBOLS unchanged)
- Create: `packages/gossip/test/architecture/boundary_test.dart`

**The boundary test (write AFTER the moves in this task, expected to PASS — it is the acceptance gate; if it fails, a move or seam is wrong — fix that, never the table):**

```dart
import 'dart:io';
import 'package:test/test.dart';

/// Part 2 spec: the machine-checked edge table (fluent's CA2-3 pattern).
/// The table IS the architecture; adding an edge means editing this test
/// in a reviewed diff.
const Map<String, Set<String>> edges = {
  'shared': {'shared'},
  // 'membership' allowed ONLY from sync/infrastructure/ (checked below).
  'sync': {'sync', 'shared', 'membership'},
  'membership': {'membership', 'shared'},
  // Composition root: may import everything. It is the graph's sink —
  // "nothing imports it" is enforced by its absence from every other row.
  'coordinator': {'coordinator', 'shared', 'sync', 'membership'},
};

void main() {
  test('every import in lib/src obeys the edge table', () {
    final violations = <String>[];
    final files = Directory('lib/src')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in files) {
      final module = file.path.split('/')[2]; // lib/src/<module>/...
      final allowed = edges[module];
      if (allowed == null) {
        violations.add('${file.path}: unknown module "$module" — '
            'extend the edge table in a reviewed diff');
        continue;
      }
      final imports = RegExp("import 'package:gossip/src/([a-z_]+)/")
          .allMatches(file.readAsStringSync())
          .map((m) => m.group(1)!);
      for (final target in imports) {
        if (!allowed.contains(target)) {
          violations.add('${file.path} imports $target');
        }
        // The concession: a context importing another context must sit
        // under its own infrastructure/.
        if (target != module &&
            target != 'shared' &&
            module != 'coordinator' &&
            !file.path.contains('/$module/infrastructure/')) {
          violations.add('${file.path} imports $target outside '
              'infrastructure/ (ACL concession violated)');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
```

(Adaptation: if any lib file still uses relative imports after Task 5's normalization, the walker must also resolve those — better: assert none exist and fail with a "normalize first" message. Keep the test self-contained; run from the package root as the suite does.)

Then full gates: `dart test && dart analyze` (gossip), then from the repo root `melos run test && melos run analyze`, then `cd examples/gossip_chat && flutter test && dart analyze` — everything green/zero (the barrel-stability proof).

Commit:
```bash
git commit -m "refactor(gossip): coordinator shell + context barrels; machine-checked boundary edge table"
```

---

### Task 9: Docs — GLOSSARY, ADR-010 rewrite, CLAUDE.md, roadmap close-out

**Files:**
- Create: `GLOSSARY.md` (repo root) — the ubiquitous language: sync context (channel, stream, entry, digest, delta, dominance, version vector, quiescence, news, partner, anti-entropy, reactive push), membership context (peer, probe, suspicion, liveness evidence, suppression, reachability), shared (HLC, node identity). One line each, plain language, cross-referencing the context that owns each term.
- Rewrite: `packages/gossip/docs/adr/010-*.md` — the context map (with the evidence-derived rationale), the boundary rule + the single ACL concession, the interior `domain/application/infrastructure` convention + kind-named subfolder taxonomy, engines-as-application, per-context codecs + WireTypes partition (no crossing module — the kt compromise dissolved, decision recorded), per-context sealed event families under an abstract base, the edge table (mirroring the boundary test), and the four gossip-kt divergences as recorded findings to port back.
- Modify: `packages/gossip/docs/adr/011-*.md` only if its text references moved paths (check; else untouched).
- Modify: root `CLAUDE.md` — the core-package architecture section: replace the five-layer description with the context map + boundary rule; update the component table's locations.
- Modify: `docs/roadmap.md` — health-architecture-alignment line → `☑` done (both parts; name the Part 2 commits), REWRITE its one-line summary (the "per gossip-kt" phrasing is stale — the shipped layout deliberately diverges; say "concept-first bounded contexts (shared/sync/membership/coordinator) with a machine-checked boundary"); `docs/backlog/health-architecture-alignment.md` Related section links this plan + spec as shipped (no status language in the backlog file).
- No test cycle (docs), but `dart analyze` after (doc-comment references) and `grep -rn "health-architecture-alignment" docs` for link hygiene.

Commit:
```bash
git commit -m "docs: GLOSSARY + ADR-010 bounded-contexts rewrite; close the architecture-alignment roadmap item"
```

---

## Self-Review Notes

- **Spec coverage:** contexts + interiors (T5-T8), boundary rule + ACL (T4, enforced T8), per-context codecs + wire types + injection (T2-T3, composite retired T7), event families (T1), barrels + edge-table test (T8), GLOSSARY/ADR/CLAUDE/roadmap (T9), public-API freeze (global constraint, proven by transports in T8), kind taxonomy (move tables + T9 ADR). Spec's out-of-scope items appear in no task. ✓
- **Deliberate sequencing deviation from the spec's migration sketch:** seams first (T1-T4), moves second (T5-T8) — every move commit is then purely mechanical and reviewable as renames; the spec's "new interfaces are TDD'd, moves ride the green gate" posture is preserved exactly.
- **Move-verbatim instructions** (codec split, event classes) follow the established Ruling-1 pattern: the source location is named; transcription into the plan would risk drift.
- **Type consistency:** `MessageCodec`/`WireTypes` (T2) consumed by T3/T7/T8 under the same names; `PeerDirectory`/`SyncPartner`/`MembershipPeerDirectory` (T4) consumed by T7's move tables and T8's edge test; the six-operation port matches the engine's verified registry surface. ✓
- **Known adaptation points (deliberate):** event constructors in T1's test; codec fixture construction mirrored from existing codec tests (T2); `PeerDirectory` parameter lists yield to the engine's real call sites (T4); the walker's relative-import guard (T8).
