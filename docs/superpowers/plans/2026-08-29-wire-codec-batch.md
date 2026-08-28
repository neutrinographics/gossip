# Wire/Codec Batch Implementation Plan (Dart ↔ Kotlin wire versioning)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the owner-approved wire-versioning spec across three repos: version-dispatching codecs (receive v1 + v2 everywhere), config-gated send (`WireVersion`, default v1 in both libraries), Dart-canonical conformance vectors vendored with checksum manifests, and the OpenDoorApp translator's `floor` mapping.

**Architecture:** Each library's per-context codec becomes a facade: byte 0 is classified by the shared wire-types table (v1 type byte `0x00`–`0x06`, v2 marker `0xF2`, everything else a reported decode error), then the family split and per-version schema modules apply. Send is selected by a `WireVersion` config enum on each coordinator config; receive is always both. gossip-kt's domain delta messages converge on Dart's flat per-(channel, stream) shape, with kt's v1 codec module mapping the deployed batched wire ↔ flat domain messages; kt's silent decode-null is replaced by reported decode outcomes. Cross-repo truth is a Dart-canonical vector directory (`packages/gossip/test/wire_vectors/`) whose sets are vendored (byte-copied, checksum-pinned) into gossip-kt. The app's translator suite consumes plain copies of the v1-kt frames and encodes its Dart-side frames with the real library codec, without manifest machinery — the shim it pins dies at v2.

**Tech Stack:** Dart (pure `dart test`) in `gossip`; Kotlin 2.1 + kotlinx-serialization + Gradle in `gossip-kt`; Flutter (`flutter test`) in OpenDoorApp.

**Spec:** `docs/superpowers/specs/2026-08-28-wire-versioning.md` (§7 schema appendix and §5.3 playbook are binding; §11 is the ruled decision record). Wire facts: `docs/superpowers/specs/2026-08-28-wire-recon-facts.md`.

## Plan-level decisions (resolved here, flagged for the owner)

These five points are where the spec under-determines the implementation; each is resolved below and every affected task cites this section. Decisions 1, 2 and 4 were folded back into the spec by its 2026-08-29 amendments and are restated here as implementation guidance, not as open questions.

1. **v1-kt payload signedness (spec gap — now CLOSED by the spec's 2026-08-29 amendment).** The spec used to declare Entry-v1 payload ints "0–255, out-of-range rejected", but deployed gossip-kt actually emits **signed** JSON ints (−128..127; pinned by kt's own `V1WireGoldenTest` fixtures: bytes 0x80/0xFF appear as −128/−1 — the goldens are ground truth). Spec §7.2/§7.4 now carry the amended rule and this plan implements exactly it, in three parts: (a) kt's v1 emission **normalizes to unsigned 0–255** (wire-compatible with every deployed receiver: kt decode uses `.toByte()`; old Dart decode `cast<int>()` accepts 0–255); (b) **every v1 decoder — Dart's included — widens to accept −128..255** and normalizes negatives (`n + 256`), rejecting only what falls outside that range; (c) the OpenDoorApp translator **normalizes incoming payload ints in flight** (−128..−1 → +256) so the dialect bridge, not the library, absorbs the deployed server's signedness. Existing kt fixture files stay byte-identical; they become decode-side vectors, with unsigned-emission counterparts pinned encode-side.
2. **kt `PingReq` — `originalRequester` is DROPPED (spec §11 decision 4).** The shared v2 vectors require byte-identical emission, and Dart never had the field. kt's engine only ever sets `originalRequester = localNode`, which is the same value it puts in `sender` (`FailureDetector.kt:491`), and its only read is of the node to answer — again that sender (`FailureDetector.kt:321`); the deployed translator likewise injects `originalRequester = sender`. Reading `sender` is therefore behavior-identical. Resolution: kt's **domain `PingReq` drops the field** and `FailureDetector` reads `sender` at both sites; the **v2 schema omits it entirely** (Dart's exact 3-key form); **v1-kt emission still emits it, set to `sender`**, for deployed compatibility, and v1 decode tolerates its absence.
3. **Decode modules are shared where schemas only differ additively.** §8a asks for "one codec module per version". In Dart, v1 and v2 payload schemas differ only additively within one key namespace, and §7.3 *mandates* keeping the tolerant decoder (legacy int-list grace, absent-`hasMore`/`floor` defaults) — so Dart ships **per-version emission modules** plus **one tolerant decoder per family**, with the facade owning framing dispatch. In kt the v1/v2 sync schemas differ structurally (batched vs flat), so kt gets true per-version decode modules. Spirit of §8a preserved: no version's *emission* schema leaks outside its module; adding v3 touches no v1/v2 code.
4. **kt pagination/budgeting is NOT in this batch — it is post-KT-B engine work.** §10 (amended 2026-08-29) keeps budget-from-active-codec on the Dart side in this batch (`maxEntryPayloadForBudget`/`encodedEntrySize` per active codec) and **reassigns kt's digest budgeting and delta pagination to the port campaign's post-KT-B engine work**: kt has no deployed transport ceiling forcing them, budgeting is engine behavior entangled with `hasMore` emission and pull tracking rather than codec behavior, and the asymmetry is wire-safe — kt honors a received `hasMore: true` with a continuation request and truthfully sends `hasMore: false`, because it always answers with a complete delta. Its durable home is the wire-versioning campaign backlog item's scope list (`docs/backlog/kt-wire-versioning-campaign.md`).

5. **The v1-mode append payload cap: strict version-aware cap (owner-ruled 2026-08-29).** With the Dart default emitting v1, the append-time payload cap under the 30KB budget drops from ~22KB (base64) to ~7.4KB (int-array worst case, 4 chars/byte): `maxEntryPayloadForBudget` takes the active `WireVersion` and `EventStream.append` rejects anything larger at write time. The alternative — keeping the ~22KB cap and letting oversized entries fail later at send time — was rejected: an explicit `ArgumentError` at the write the app controls beats a silent non-convergence at a send it does not see, and the cap has always been a derived write-time guard rather than a published constant. The band is narrow in practice (the deployed nearby path already limits payload sizes well under it) and it **self-heals at the v2 flip**, when the same budget yields the ~22KB figure again. The drop is a behavior change for library consumers and is disclosed in the CHANGELOG task (W-D7).

## Global Constraints

- **Receivers before senders (hard ordering invariant, §5.2):** all receive-both dispatch work (W-D1–W-D3, W-K1–W-K6) lands before any task or config flips a sender to v2. Both config defaults are `v1`; no task in this plan flips any deployed sender. Task R1 is the §5.3-step-3 gate: "No sender may flip to v2 before this step is green."
- **Config defaults, verbatim from §11 decision 1:** enum `WireVersion.v1`/`WireVersion.v2`; "Default is **`.v1` in BOTH libraries**." Codec constructors take the version explicitly (no codec-level default); the ruled default lives exactly once per library, on the coordinator config.
- **Marker table (§3.3):** `0x00`–`0x06` v1 frame; `0xF2` v2 marker; `0x07`–`0xEF`, `0xF0`–`0xF1`, unregistered `0xF3`–`0xFE`, and `0xFF` are decode errors — reported, frame dropped, receive loop survives. Never silent.
- **Per-task gates.** Every task ends with the owning repo fully green before commit:
  - gossip: `cd /Users/joel/git/neutrinographics/gossip/packages/gossip && dart test && dart analyze` (baseline ~1190 tests — **measure at W-D1 step 0 and record; never inherit counts**; zero analyze issues; `test/architecture/boundary_test.dart` runs inside the suite).
  - gossip-kt: `cd /Users/joel/git/neutrinographics/gossip-kt && ./gradlew test` (baseline 629 tests — measure at W-K1; `BoundaryTest` runs inside the suite).
  - OpenDoorApp: `cd /Users/joel/git/neutrinographics/OpenDoorApp && flutter test test/features/sync` (measure at W-T2 step 0).
  - All golden/vector tests are part of these suites and must be green at every commit.
- **Goldens are never regenerated without disclosure.** Existing fixture files (`gossip-kt/src/test/resources/wire/v1-kt/*.frame`, `checksums.txt`) stay byte-identical through the whole batch; a task that adds fixtures or changes a fixture's *role* (encode+decode → decode-only) says so in its commit message. Dart's inline wire-pinning JSON literals move into explicit-version test groups but their key sets/values are not edited (the only pinned change: v2 frames gain the two-byte `0xF2` prefix — disclosed in W-D2's commit). No `regenerate = true` flag is ever committed.
- **Branch / commit / PR conventions per repo:**
  - gossip: NEW branch `wire-versioning` off `working-connection`. Conventional commits (`feat(sync): …`), each ending `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Phase ends with a PR to `working-connection`; Joel squash-merges.
  - gossip-kt: continue committing directly on `feature/compaction` (HEAD `3836bc7`). Conventional style matching the log (`feat(wire): …`, `refactor(sync): …`), no co-author footer (repo log has none).
  - OpenDoorApp: NEW branch `wire-floor-translation` off `main`; PR to `main`. Commit style per repo log: short imperative summary (Joel prepends a ClickUp ID at merge if he wants one).
  - Signing: gossip and gossip-kt have `commit.gpgsign=true` in git config — leave signing configuration untouched; OpenDoorApp is unsigned.
- **No campaign references in code comments** (no batch names, no spec file paths in `lib/`/`src/` comments — doc comments state the wire contract's intent, per the standing "docs explain why, not how" rule). Plans/commit messages may cite the spec.
- **No silent errors:** every decode failure surfaces via `ErrorCallback` (Dart) or the new `DecodeResult.Malformed` → `onError` path (kt).
- **Spec §7 is the schema tiebreaker** when the two codebases disagree.

## File map

**Phase W-D (gossip, branch `wire-versioning`):**
- Modify `lib/src/shared/domain/value_objects/wire_types.dart` — marker table + frame classification.
- Create `lib/src/shared/domain/value_objects/wire_version.dart` — `WireVersion` enum.
- Modify `lib/src/sync/infrastructure/sync_message_codec.dart` — facade: dispatch + shared tolerant decode.
- Create `lib/src/sync/infrastructure/sync_wire_emission.dart` — per-version emission modules.
- Modify `lib/src/membership/infrastructure/membership_message_codec.dart` — versioned framing.
- Modify `lib/src/coordinator/coordinator_config.dart`, `lib/src/coordinator/coordinator.dart`, `lib/gossip.dart`.
- Create `test/wire_vectors/{v1-dart,v1-kt,v2,edge}/` + `test/wire_vectors/wire_vectors_test.dart`.

**Phase W-K (gossip-kt, branch `feature/compaction`):**
- Modify `shared/domain/values/WireTypes.kt`; create `shared/domain/values/WireVersion.kt`.
- Rewrite `shared/domain/interfaces/MessageCodec.kt` — `DecodeResult`.
- Modify `membership/infrastructure/MembershipMessageCodec.kt`, `coordinator/Coordinator.kt`, `coordinator/CoordinatorConfig.kt`.
- Rewrite `sync/domain/messages/DeltaRequest.kt`, `DeltaResponse.kt` (flat); modify `sync/application/GossipEngine.kt`.
- Split `sync/infrastructure/SyncMessageCodec.kt` into facade + `SyncWireV1.kt` + `SyncWireV2.kt`.
- Extend `src/test/resources/wire/` with vendored `v1-kt` additions, `v2/`, `edge/`.

**Phase W-T (OpenDoorApp, branch `wire-floor-translation`):**
- Modify `lib/features/sync/infrastructure/gossip/protocol_translator.dart`.
- Create `test/features/sync/infrastructure/gossip/wire_vectors/v1-kt/` (plain byte-copies of the v1-kt frames, no manifest); extend `test/features/sync/infrastructure/gossip/protocol_translator_test.dart`.

---

# Phase W-D — gossip (Dart), branch `wire-versioning`

### Task W-D1: Marker table and `WireVersion` enum

**Files:**
- Modify: `packages/gossip/lib/src/shared/domain/value_objects/wire_types.dart`
- Create: `packages/gossip/lib/src/shared/domain/value_objects/wire_version.dart`
- Test: `packages/gossip/test/shared/domain/value_objects/wire_types_test.dart`

**Interfaces:**
- Produces: `enum WireVersion { v1, v2 }`; `WireTypes.markerV2` (`0xF2`); `static int WireTypes.frameTypeOffset(Uint8List bytes)` — returns 0 for a v1 frame, 1 for a `0xF2`-prefixed frame, throws `ArgumentError` for empty frames, reserved bytes (`0x07`–`0xEF`), unassigned markers (`0xF0`–`0xF1`, `0xF3`–`0xFE`), the `0xFF` escape, and a marker with no byte after it. Used by both codec facades in W-D2/W-D3.

- [ ] **Step 0: Create the branch and record the baseline**

```bash
cd /Users/joel/git/neutrinographics/gossip
git checkout working-connection && git pull && git checkout -b wire-versioning
cd packages/gossip && dart test 2>&1 | tail -3   # record the measured test count (expected ≈1190)
```

- [ ] **Step 1: Write the failing tests** (append to `wire_types_test.dart`; add `import 'dart:typed_data';` and the wire_version import):

```dart
group('version marker table', () {
  test('0xF2 is the v2 marker and markers do not collide with type bytes', () {
    expect(WireTypes.markerV2, equals(0xF2));
    expect(WireTypes.known.contains(WireTypes.markerV2), isFalse);
  });

  test('frameTypeOffset is 0 for v1 frames and 1 for v2 frames', () {
    expect(WireTypes.frameTypeOffset(Uint8List.fromList([3, 123])), equals(0));
    expect(
      WireTypes.frameTypeOffset(Uint8List.fromList([0xF2, 3, 123])),
      equals(1),
    );
  });

  test('empty, reserved, unassigned-marker and escape bytes all throw', () {
    for (final frame in [
      <int>[],
      [0x07], [0x80], [0xEF],      // reserved gap
      [0xF0, 3], [0xF1, 3],        // permanently unassigned markers
      [0xF3, 3], [0xFE, 3],        // unregistered versions
      [0xFF, 3],                   // escape byte
      [0xF2],                      // marker with nothing after it
    ]) {
      expect(
        () => WireTypes.frameTypeOffset(Uint8List.fromList(frame)),
        throwsArgumentError,
        reason: 'frame $frame',
      );
    }
  });

  test('WireVersion has exactly v1 and v2', () {
    expect(WireVersion.values, [WireVersion.v1, WireVersion.v2]);
  });
});
```

- [ ] **Step 2: Run to verify failure** — `dart test test/shared/domain/value_objects/wire_types_test.dart` → FAIL (missing members).

- [ ] **Step 3: Implement.** New `wire_version.dart`:

```dart
/// The wire dialect this node EMITS. Receivers always accept every
/// registered version regardless of this setting — only send is gated,
/// so a mixed fleet keeps interoperating while configs are rolled out.
enum WireVersion {
  /// Legacy unprefixed frames: `[type byte][JSON]`. Entry payloads are
  /// JSON int arrays and DeltaResponse never carries `hasMore`
  /// (continuation degrades to later anti-entropy rounds). The additive
  /// `floor` field IS emitted so upgraded peers get compaction interop;
  /// legacy decoders ignore unknown keys.
  v1,

  /// Prefixed frames: `[0xF2][type byte][JSON]`. Base64 entry payloads,
  /// `hasMore` always present, `floor` when non-empty.
  v2,
}
```

Additions to `WireTypes` (plus `import 'dart:typed_data';`):

```dart
  /// First byte of every v2 frame. Marker bytes encode the version
  /// directly: version = byte - 0xF0. 0xF0/0xF1 are permanently
  /// unassigned (v0 does not exist; v1 is *defined* as the unprefixed
  /// form), 0xF3-0xFE are unregistered until a version claims them, and
  /// 0xFF is reserved as an escape for a future extended-version form.
  static const int markerV2 = 0xF2;

  /// Classifies a frame's leading byte(s) and returns the index of the
  /// type byte: 0 for a v1 frame, 1 for a registered-marker frame.
  ///
  /// Owning this here keeps marker-range knowledge in the same shared
  /// envelope agreement that owns the type-byte partition: the codec
  /// facades never read marker semantics themselves. Throws
  /// [ArgumentError] for anything undecodable by every codec — empty
  /// frames, reserved bytes, unassigned markers, the escape byte, or a
  /// marker with no type byte after it.
  static int frameTypeOffset(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw ArgumentError('Cannot decode empty bytes');
    }
    final first = bytes[0];
    if (known.contains(first)) return 0;
    if (first == markerV2) {
      if (bytes.length < 2) {
        throw ArgumentError('Version marker with no type byte');
      }
      return 1;
    }
    throw ArgumentError('Unknown message type: $first');
  }
```

- [ ] **Step 4: Run to verify pass** — same command, then the full gate (`dart test && dart analyze`).

- [ ] **Step 5: Commit**

```bash
git add lib/src/shared/domain/value_objects/ test/shared/domain/value_objects/wire_types_test.dart
git commit -m "feat(wire): register the v2 version-marker table on WireTypes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task W-D2: Sync codec — version-dispatching facade with v1/v2 emission modules

**Files:**
- Modify: `packages/gossip/lib/src/sync/infrastructure/sync_message_codec.dart`
- Create: `packages/gossip/lib/src/sync/infrastructure/sync_wire_emission.dart`
- Modify: `packages/gossip/lib/src/coordinator/coordinator.dart:279-281,316` (constructor sites only, temporary explicit `WireVersion.v2` — replaced by config in W-D4)
- Test: `packages/gossip/test/sync/infrastructure/sync_message_codec_test.dart` + mechanical constructor updates across `test/` (list in step 5)

**Interfaces:**
- Consumes: `WireVersion`, `WireTypes.frameTypeOffset`, `WireTypes.markerV2` (W-D1).
- Produces: `SyncMessageCodec({required WireVersion wireVersion})` (still `implements MessageCodec`; `decode` contract per version preserved: sibling-family → null, unknown → throw); `abstract interface class SyncWireEmission { Uint8List frame(int messageType, List<int> jsonBytes); Map<String, dynamic> deltaResponseJson(DeltaResponse message); int encodedEntrySize(LogEntry entry); }` with `const SyncEmissionV1()` / `const SyncEmissionV2()`; `static int SyncMessageCodec.maxEntryPayloadForBudget(int budgetBytes, WireVersion version)`; top-level helpers `Map<String, int> versionVectorJson(VersionVector v)` and `Map<String, dynamic> entryEnvelopeJson(LogEntry entry)` in `sync_wire_emission.dart`.

- [ ] **Step 1: Write the failing tests.** In `sync_message_codec_test.dart`, add a dispatch group (top of the main group; `codec` fixtures become explicit-version):

```dart
group('version dispatch', () {
  final v1 = SyncMessageCodec(wireVersion: WireVersion.v1);
  final v2 = SyncMessageCodec(wireVersion: WireVersion.v2);

  test('v2 frames decode identically to v1 frames of the same message', () {
    final request = DeltaRequest(
      sender: NodeId('peer1'),
      channelId: ChannelId('ch1'),
      streamId: StreamId('s1'),
      since: VersionVector({NodeId('peer1'): 3}),
    );
    final fromV1 = v1.decode(v1.encode(request)) as DeltaRequest;
    final fromV2 = v1.decode(v2.encode(request)) as DeltaRequest; // decode is version-agnostic
    expect(fromV2.since[NodeId('peer1')], equals(fromV1.since[NodeId('peer1')]));
    expect(fromV2.channelId, equals(request.channelId));
  });

  test('a v2-prefixed membership frame decodes to null (sibling family)', () {
    // [0xF2][ping type byte][json] — the marker must not turn routine
    // sibling traffic into an error in either engine's codec.
    final frame = Uint8List.fromList([
      0xF2, 0, ...utf8.encode('{"sender":"p","sequence":1}'),
    ]);
    expect(v1.decode(frame), isNull);
    expect(v2.decode(frame), isNull);
  });

  test('reserved and unassigned first bytes throw in every version', () {
    for (final first in [0x07, 0x80, 0xF0, 0xF1, 0xF3, 0xFF]) {
      final frame = Uint8List.fromList([first, 1, 2]);
      expect(() => v1.decode(frame), throwsArgumentError, reason: '$first');
      expect(() => v2.decode(frame), throwsArgumentError, reason: '$first');
    }
  });

  test('a v2 frame with an unknown type byte throws', () {
    expect(
      () => v1.decode(Uint8List.fromList([0xF2, 0x50, 1])),
      throwsArgumentError,
    );
  });

  test('a signed int-array payload decodes to the unsigned bytes', () {
    // The deployed Kotlin server emits payload bytes sign-extended
    // (-128..-1 for 0x80..0xFF), so the legacy reader must accept and
    // normalize them; only values outside -128..255 are corruption.
    final decoded = v2.decode(deltaResponseFrameWithPayload([0, -1, -128, 255]))
        as DeltaResponse;
    expect(decoded.entries.single.payload, equals([0, 255, 128, 255]));
    expect(
      () => v2.decode(deltaResponseFrameWithPayload([300])),
      throwsArgumentError,
    );
  });
});
```

Split the existing `encode-side wire pinning` group in two (existing JSON key-set/value literals move verbatim — only bytes-0/1 expectations are version-specific):

```dart
group('v1 emission wire pinning', () {
  // Literals are hand-copied from spec §7.2, not read from the codec.
  final codec = SyncMessageCodec(wireVersion: WireVersion.v1);

  test('DeltaResponse encodes type byte 6, no marker, no hasMore, '
      'int-array payload, and an additive floor when non-empty', () {
    final encoded = codec.encode(DeltaResponse(
      sender: NodeId('peer2'),
      channelId: ChannelId('ch1'),
      streamId: StreamId('s1'),
      entries: [
        LogEntry(
          author: NodeId('peer1'),
          sequence: 1,
          timestamp: Hlc(1000, 2),
          payload: Uint8List.fromList([1, 2, 3]),
        ),
      ],
      hasMore: true, // domain flag set — must NOT reach the v1 wire
      floor: VersionVector({NodeId('peer1'): 3}),
    ));

    expect(encoded[0], equals(6));
    final json = jsonOf(encoded);
    expect(
      json.keys.toSet(),
      equals({'sender', 'channelId', 'streamId', 'entries', 'floor'}),
      reason: 'hasMore stays v2-only; floor is the ruled additive field',
    );
    final entry = (json['entries'] as List).single as Map<String, dynamic>;
    expect(entry['payload'], equals([1, 2, 3]));
    expect(json['floor'], equals({'peer1': 3}));
  });

  test('DeltaResponse with an empty floor omits the floor key', () {
    final encoded = codec.encode(responseWith(const []));
    expect(
      jsonOf(encoded).keys.toSet(),
      equals({'sender', 'channelId', 'streamId', 'entries'}),
    );
  });

  test('types 3-5 emit unprefixed with the same key sets as v2', () {
    final request = DigestRequest(sender: NodeId('peer1'), digests: const []);
    final encoded = codec.encode(request);
    expect(encoded[0], equals(3));
    expect(jsonOf(encoded).keys.toSet(), equals({'sender', 'digests'}));
  });
});
```

The existing pinning tests become `group('v2 emission wire pinning', ...)` with `codec = SyncMessageCodec(wireVersion: WireVersion.v2)` and their byte assertions updated from `expect(encoded[0], equals(N))` to:

```dart
    expect(encoded[0], equals(0xF2));
    expect(encoded[1], equals(N));
```

and `jsonOf` gains a version-aware sublist (`bytes.sublist(WireTypes.frameTypeOffset(bytes) + 1)`). All other literals (key sets, `'AQID'`, `hasMore` presence, floor map) are moved unchanged.

- [ ] **Step 2: Run to verify failure** — `dart test test/sync/infrastructure/sync_message_codec_test.dart` → FAIL (no `wireVersion` parameter).

- [ ] **Step 3: Implement.** New `sync_wire_emission.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_types.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';

/// Shared JSON pieces identical across wire versions.
Map<String, int> versionVectorJson(VersionVector version) =>
    version.entries.map((k, v) => MapEntry(k.value, v));

Map<String, dynamic> entryEnvelopeJson(LogEntry entry) => {
  'author': entry.author.value,
  'sequence': entry.sequence,
  'timestamp': {
    'physicalMs': entry.timestamp.physicalMs,
    'logical': entry.timestamp.logical,
  },
};

/// Per-version SEND-side strategy: owns the frame framing and the only
/// payload schema that differs between versions (DeltaResponse and its
/// entry encoding). Decode stays on the facade's single tolerant decoder,
/// which the wire contract requires to accept both versions' additive
/// shapes.
abstract interface class SyncWireEmission {
  Uint8List frame(int messageType, List<int> jsonBytes);
  Map<String, dynamic> deltaResponseJson(DeltaResponse message);

  /// Encoded size of one entry inside this version's `entries` array —
  /// budgeting must track the ACTIVE send codec, not a fixed formula.
  int encodedEntrySize(LogEntry entry);
}

/// Legacy unprefixed emission: `[type][JSON]`, int-array payloads, no
/// hasMore (continuation degrades to later rounds), additive floor.
class SyncEmissionV1 implements SyncWireEmission {
  const SyncEmissionV1();

  @override
  Uint8List frame(int messageType, List<int> jsonBytes) {
    final result = Uint8List(1 + jsonBytes.length);
    result[0] = messageType;
    result.setRange(1, result.length, jsonBytes);
    return result;
  }

  @override
  Map<String, dynamic> deltaResponseJson(DeltaResponse message) => {
    'sender': message.sender.value,
    'channelId': message.channelId.value,
    'streamId': message.streamId.value,
    'entries': [for (final e in message.entries) _entryJson(e)],
    if (message.floor.entries.isNotEmpty)
      'floor': versionVectorJson(message.floor),
  };

  Map<String, dynamic> _entryJson(LogEntry entry) => {
    ...entryEnvelopeJson(entry),
    'payload': entry.payload.toList(),
  };

  @override
  int encodedEntrySize(LogEntry entry) =>
      utf8.encode(jsonEncode(_entryJson(entry))).length;
}

/// Prefixed emission: `[0xF2][type][JSON]`, base64 payloads, hasMore
/// always present, floor when non-empty.
class SyncEmissionV2 implements SyncWireEmission {
  const SyncEmissionV2();

  @override
  Uint8List frame(int messageType, List<int> jsonBytes) {
    final result = Uint8List(2 + jsonBytes.length);
    result[0] = WireTypes.markerV2;
    result[1] = messageType;
    result.setRange(2, result.length, jsonBytes);
    return result;
  }

  @override
  Map<String, dynamic> deltaResponseJson(DeltaResponse message) => {
    'sender': message.sender.value,
    'channelId': message.channelId.value,
    'streamId': message.streamId.value,
    'entries': [for (final e in message.entries) _entryJson(e)],
    'hasMore': message.hasMore,
    if (message.floor.entries.isNotEmpty)
      'floor': versionVectorJson(message.floor),
  };

  Map<String, dynamic> _entryJson(LogEntry entry) => {
    ...entryEnvelopeJson(entry),
    'payload': base64Encode(entry.payload),
  };

  @override
  int encodedEntrySize(LogEntry entry) =>
      utf8.encode(jsonEncode(_entryJson(entry))).length;
}
```

Facade changes in `sync_message_codec.dart`:

```dart
class SyncMessageCodec implements MessageCodec {
  SyncMessageCodec({required this.wireVersion})
    : _emission = switch (wireVersion) {
        WireVersion.v1 => const SyncEmissionV1(),
        WireVersion.v2 => const SyncEmissionV2(),
      };

  /// The dialect this codec EMITS; decode always accepts both.
  final WireVersion wireVersion;
  final SyncWireEmission _emission;

  @override
  Uint8List encode(ProtocolMessage message) {
    final messageType = _getMessageType(message);
    final Map<String, dynamic> json;
    if (message is DigestRequest) {
      json = _encodeDigestRequest(message);
    } else if (message is DigestResponse) {
      json = _encodeDigestResponse(message);
    } else if (message is DeltaRequest) {
      json = _encodeDeltaRequest(message);
    } else if (message is DeltaResponse) {
      json = _emission.deltaResponseJson(message);
    } else {
      throw ArgumentError('Unknown message type: ${message.runtimeType}');
    }
    return _emission.frame(messageType, utf8.encode(jsonEncode(json)));
  }

  @override
  ProtocolMessage? decode(Uint8List bytes) {
    final offset = WireTypes.frameTypeOffset(bytes);
    final messageType = bytes[offset];
    if (!WireTypes.sync.contains(messageType)) {
      // Sibling-family traffic is routine "not mine" in EVERY version;
      // a type byte no context owns is corruption in every version.
      if (!WireTypes.known.contains(messageType)) {
        throw ArgumentError('Unknown message type: $messageType');
      }
      return null;
    }
    return _decodeMessageData(messageType, bytes.sublist(offset + 1));
  }

  int encodedEntrySize(LogEntry entry) => _emission.encodedEntrySize(entry);

  static int maxEntryPayloadForBudget(int budgetBytes, WireVersion version) {
    final usable = budgetBytes - _entryEnvelopeOverhead;
    if (usable <= 0) return 0;
    return switch (version) {
      // Int-array worst case: "255," — 4 chars per payload byte.
      WireVersion.v1 => usable ~/ 4,
      // Base64: 4 chars carry 3 payload bytes.
      WireVersion.v2 => (usable ~/ 4) * 3,
    };
  }
  // _encodeDeltaResponse, _encodeLogEntries, _encodeLogEntry are DELETED
  // (moved into the emission modules); _encodeVersionVector is replaced
  // by versionVectorJson; encodedStreamDigestSize and the decoders stay
  // as they are (the tolerant decoder already handles int-list payloads
  // and absent hasMore/floor) with ONE change: the int-list payload
  // reader at :319-335 widens from 0..255 to -128..255, normalizing a
  // negative element to n + 256 and rejecting only what falls outside
  // that range (spec §7.2 as amended — the deployed kt server emits
  // signed bytes, so the narrow rule rejected live traffic).
}
```

`coordinator.dart` (temporary until W-D4): `SyncMessageCodec(wireVersion: WireVersion.v2)` at :316 and `SyncMessageCodec.maxEntryPayloadForBudget(cfg.maxMessageBytes, WireVersion.v2)` at :279.

- [ ] **Step 4: Mechanically update every `SyncMessageCodec()` construction site.** Find them:

```bash
grep -rln "SyncMessageCodec()" lib test
```

Known sites: `test/sync/application/gossip_engine_test_harness.dart` (3× — give the harness factory and `buildEngine` a `WireVersion wireVersion = WireVersion.v2` parameter and plumb it to every codec construction; harness default v2 preserves what the existing suite pins), `test/error_emission_test.dart`, `test/coordinator/coordinator_merge_fold_error_test.dart`, `coordinator_reactive_push_test.dart`, `coordinator_sync_activity_test.dart`, `coordinator_sync_on_connect_test.dart`, `coordinator_lifecycle_test.dart`, `test/integration/adverse/duplicate_frames_test.dart`, `test/sync/application/digest_budgeter_test.dart`, `gossip_engine_digest_budget_test.dart`, `gossip_engine_message_handling_test.dart`, `engine_codec_injection_test.dart`, `gossip_engine_scheduling_test.dart`, and the codec test itself. Default choice for existing tests: `wireVersion: WireVersion.v2` (they pin current behavior). Any call to `maxEntryPayloadForBudget` in tests gains the explicit version argument matching what the test pins.

- [ ] **Step 5: Run to verify pass** — `dart test && dart analyze`. Expect the measured baseline + ~7 new tests, minus nothing.

- [ ] **Step 6: Commit** (disclosure line required):

```bash
git add lib test
git commit -m "feat(sync): version-dispatching sync codec with v1/v2 emission modules

The encode-side wire-pinning group splits into v1 and v2 groups; the v2
group's frames now pin the 0xF2 marker prefix (payload literals moved
unchanged). Codec construction requires an explicit WireVersion.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task W-D3: Membership codec — versioned framing

**Files:**
- Modify: `packages/gossip/lib/src/membership/infrastructure/membership_message_codec.dart`
- Modify: `packages/gossip/lib/src/coordinator/coordinator.dart:334` (temporary `WireVersion.v2`)
- Test: `packages/gossip/test/membership/infrastructure/membership_message_codec_test.dart` (+ constructor sites found via `grep -rln "MembershipMessageCodec()" lib test`)

**Interfaces:**
- Consumes: `WireVersion`, `WireTypes.frameTypeOffset`, `WireTypes.markerV2`.
- Produces: `MembershipMessageCodec({required WireVersion wireVersion})`. Membership JSON schemas are byte-identical across versions (§7.3: types 0–2 identical to v1), so this facade has no emission modules — only framing differs; the class doc says so.

- [ ] **Step 1: Write the failing tests** (in `membership_message_codec_test.dart`):

```dart
group('version dispatch', () {
  final v1 = MembershipMessageCodec(wireVersion: WireVersion.v1);
  final v2 = MembershipMessageCodec(wireVersion: WireVersion.v2);

  test('v2 frames carry the marker then the identical v1 JSON payload', () {
    final ping = Ping(sender: NodeId('peer1'), sequence: 7);
    final v1Frame = v1.encode(ping);
    final v2Frame = v2.encode(ping);
    expect(v2Frame[0], equals(0xF2));
    expect(v2Frame.sublist(1), equals(v1Frame));
  });

  test('both versions decode both framings', () {
    final ping = Ping(sender: NodeId('peer1'), sequence: 7);
    for (final codec in [v1, v2]) {
      for (final frame in [v1.encode(ping), v2.encode(ping)]) {
        expect((codec.decode(frame)! as Ping).sequence, equals(7));
      }
    }
  });

  test('a v2-prefixed sync frame decodes to null; reserved bytes throw', () {
    final syncFrame = Uint8List.fromList([
      0xF2, 3, ...utf8.encode('{"sender":"p","digests":[]}'),
    ]);
    expect(v1.decode(syncFrame), isNull);
    expect(() => v1.decode(Uint8List.fromList([0xF3, 0, 1])), throwsArgumentError);
    expect(() => v1.decode(Uint8List.fromList([0xF2, 0x50, 1])), throwsArgumentError);
  });
});
```

- [ ] **Step 2: Run to verify failure** — `dart test test/membership/infrastructure/membership_message_codec_test.dart`.

- [ ] **Step 3: Implement.** Constructor + framing + dispatch (encode body keeps `_encodeMessageData` unchanged):

```dart
class MembershipMessageCodec implements MessageCodec {
  MembershipMessageCodec({required this.wireVersion});

  /// The dialect this codec EMITS; decode always accepts both. Membership
  /// payload schemas are identical in v1 and v2 — only the frame differs,
  /// so unlike the sync codec there are no per-version emission modules.
  final WireVersion wireVersion;

  @override
  Uint8List encode(ProtocolMessage message) {
    final messageType = _getMessageType(message);
    final data = _encodeMessageData(message);
    final prefix = wireVersion == WireVersion.v2
        ? [WireTypes.markerV2, messageType]
        : [messageType];
    final result = Uint8List(prefix.length + data.length);
    result.setRange(0, prefix.length, prefix);
    result.setRange(prefix.length, result.length, data);
    return result;
  }

  @override
  ProtocolMessage? decode(Uint8List bytes) {
    final offset = WireTypes.frameTypeOffset(bytes);
    final messageType = bytes[offset];
    if (!WireTypes.membership.contains(messageType)) {
      if (!WireTypes.known.contains(messageType)) {
        throw ArgumentError('Unknown message type: $messageType');
      }
      return null;
    }
    return _decodeMessageData(messageType, bytes.sublist(offset + 1));
  }
  // _getMessageType/_encodeMessageData/_decodeMessageData unchanged.
}
```

Update `coordinator.dart:334` to `MembershipMessageCodec(wireVersion: WireVersion.v2)` (temporary) and all other construction sites (failure-detector tests etc.) to explicit `WireVersion.v2`.

- [ ] **Step 4: Run to verify pass** — `dart test && dart analyze`.

- [ ] **Step 5: Commit**

```bash
git add lib test
git commit -m "feat(membership): version-dispatching membership codec

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task W-D4: `wireVersion` on CoordinatorConfig, default v1, plumbed end-to-end

**Files:**
- Modify: `packages/gossip/lib/src/coordinator/coordinator_config.dart`
- Modify: `packages/gossip/lib/src/coordinator/coordinator.dart:279,316,334`
- Modify: `packages/gossip/lib/gossip.dart` (export `wire_version.dart`; verify `coordinator_config.dart` is already exported)
- Create: `packages/gossip/test/coordinator/coordinator_wire_version_test.dart`

**Interfaces:**
- Consumes: `WireVersion`, both codec facades (W-D2/W-D3), `createTestCoordinator({CoordinatorConfig? config, ...})` from `test/support/coordinator_builder.dart`.
- Produces: `CoordinatorConfig.wireVersion` (`WireVersion`, default `WireVersion.v1` — the ruled library default, §11 decision 1).

- [ ] **Step 1: Write the failing tests** (`coordinator_wire_version_test.dart`; follow the existing style of `test/coordinator/coordinator_test.dart` and use `createTestCoordinator` from `../support/coordinator_builder.dart`):

```dart
void main() {
  test('the default wire version is v1', () {
    expect(CoordinatorConfig.defaults.wireVersion, equals(WireVersion.v1));
  });

  test('two default-config coordinators sync over unprefixed v1 frames', () async {
    // Build a two-coordinator pair on a shared InMemoryMessageBus (same
    // pattern as the existing coordinator sync tests), tap the bus/port
    // for raw frames, append one entry on A, pump until B holds it.
    // Assert: every observed frame's first byte is <= 0x06 (no marker),
    // and B received the entry (int-array payloads decoded fine).
  });

  test('wireVersion v2 emits marked frames and still syncs', () async {
    // Same pair with CoordinatorConfig(wireVersion: WireVersion.v2):
    // assert every observed gossip frame starts with 0xF2 and the entry
    // arrives. This is the "receive-both" proof at coordinator level.
  });

  test('a v2 frame is handled once, with zero errors emitted', () async {
    // One default-config (v1-sending) coordinator; inject a v2-encoded
    // DigestRequest frame through its message port; assert the errors
    // list stays empty (the marker decodes to null in the membership
    // codec, not to a second ArgumentError) and a DigestResponse reply
    // is produced. Pins the double-codec dispatch constraint (recon §3c).
  });
}
```

Write the four bodies concretely against `coordinator_builder.dart`'s actual API (it exposes `config:`; mirror an existing two-coordinator test for the bus wiring — `test/coordinator/coordinator_sync_on_connect_test.dart` is the closest model).

- [ ] **Step 2: Run to verify failure** — `dart test test/coordinator/coordinator_wire_version_test.dart` → FAIL (no `wireVersion` on config).

- [ ] **Step 3: Implement.** `coordinator_config.dart` gains:

```dart
  /// The wire dialect this node EMITS ([WireVersion.v1] by default).
  /// Receive always accepts every registered version regardless of this
  /// setting, so upgrading the library changes nothing on the wire until
  /// the deployment explicitly flips this to [WireVersion.v2] — which is
  /// only safe once every peer that can hear this node has upgraded to a
  /// receive-both build.
  final WireVersion wireVersion;
```

with constructor default `this.wireVersion = WireVersion.v1` and an import of the shared value object. `coordinator.dart`: replace the three temporary `WireVersion.v2` literals with `cfg.wireVersion`. `gossip.dart`: `export 'src/shared/domain/value_objects/wire_version.dart';`.

- [ ] **Step 4: Audit tests that break under the v1 default.** The coordinator-level default flip changes two things for coordinator-built tests: frames are unprefixed int-array (fine — tolerant decode), and the append-time payload cap shrinks to `maxEntryPayloadForBudget(30KB, v1)` ≈ 7.4KB. Find and fix casualties by running the suite and by:

```bash
grep -rn "hasMore" test/coordinator test/integration
grep -rn "List.filled(\s*[0-9]\{5,\}" test
```

Tests that pin v2-only wire behavior through a Coordinator get `config: CoordinatorConfig(wireVersion: WireVersion.v2)`; tests appending >7KB payloads through a default-config coordinator either shrink the payload or pin v2 explicitly. Record each choice in the commit body.

- [ ] **Step 5: Run to verify pass** — `dart test && dart analyze`.

- [ ] **Step 6: Commit**

```bash
git add lib test
git commit -m "feat(coordinator): wireVersion config selects the send dialect, default v1

Send is config-gated; receive is always both. The append-time payload
cap now tracks the active send codec (v1 int-array worst case), so
default-config coordinators accept ~7.4KB payloads under the 30KB
budget instead of ~22KB. [list any test pins made in step 4]

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task W-D5: v1-mode truncation degrades gracefully without `hasMore` (engine test)

**Files:**
- Modify: `packages/gossip/test/sync/application/gossip_engine_test_harness.dart` (already has the `wireVersion` factory param from W-D2 step 4)
- Create: `packages/gossip/test/sync/application/gossip_engine_v1_degradation_test.dart`

**Interfaces:**
- Consumes: `GossipEngineTestHarness({WireVersion wireVersion, int? maxMessageBytes, ...})`, `h.deliverDeltaRequest`, `h.captureMessages`, `h.appendEntry`.

Spec §7.2 requires this: "Implementers should verify this degradation path with a vector-driven engine test rather than taking it on faith."

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:convert';
import 'dart:typed_data';
// ... same imports as gossip_engine_catchup_test.dart, plus WireVersion.

void main() {
  test('v1-mode truncation converges through repeated pulls; '
      'no frame ever carries hasMore', () async {
    final h = GossipEngineTestHarness(
      wireVersion: WireVersion.v1,
      maxMessageBytes: 4096,
    );
    final peer = h.addPeer('peer1');
    final channelId = ChannelId('ch1');
    final streamId = StreamId('s1');
    await h.createChannelWithStream(channelId, streamId);

    // 6 entries at ~2.5KB encoded each (v1 int-array) → one entry per
    // 4KB page → convergence needs multiple pulls.
    for (var seq = 1; seq <= 6; seq++) {
      await h.appendEntry(
        channelId,
        streamId,
        LogEntry(
          author: h.localNode,
          sequence: seq,
          timestamp: Hlc(1000 + seq, 0),
          payload: Uint8List.fromList(List.filled(600, 200)),
        ),
      );
    }

    final rawFrames = <Uint8List>[];
    final rawSub = peer.port.incoming.listen((m) => rawFrames.add(m.bytes));
    final (messages, sub) = h.captureMessages(peer);

    var since = VersionVector.empty;
    var received = 0;
    var pulls = 0;
    while (received < 6 && pulls < 10) {
      pulls++;
      await h.deliverDeltaRequest(
        from: peer, channelId: channelId, streamId: streamId, since: since);
      final response = messages.whereType<DeltaResponse>().last;
      expect(response.hasMore, isFalse,
          reason: 'v1 wire never carries hasMore; decode defaults to false');
      received += response.entries.length;
      since = VersionVector({h.localNode: received});
    }

    expect(received, equals(6), reason: 'all pages arrive across pulls');
    expect(pulls, greaterThan(1), reason: 'the backlog really was paginated');
    for (final frame in rawFrames) {
      expect(frame[0], lessThanOrEqualTo(6), reason: 'unprefixed v1 frames');
      final json =
          jsonDecode(utf8.decode(frame.sublist(1))) as Map<String, dynamic>;
      expect(json.containsKey('hasMore'), isFalse);
    }

    await rawSub.cancel();
    await sub.cancel();
    await h.dispose();
  });
}
```

- [ ] **Step 2: Run to verify failure/pass honestly** — `dart test test/sync/application/gossip_engine_v1_degradation_test.dart`. This test may pass first try (the engine already truncates; v1 emission already drops `hasMore` after W-D2). That is acceptable — it is a pin, not a driver; verify it FAILS if you temporarily make `SyncEmissionV1.deltaResponseJson` emit `hasMore` (mutate, watch it fail, revert).

- [ ] **Step 3: Full gate** — `dart test && dart analyze`.

- [ ] **Step 4: Commit**

```bash
git add test
git commit -m "test(sync): v1-mode truncation converges without hasMore

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task W-D6: Canonical conformance vector directory

**Files:**
- Create: `packages/gossip/test/wire_vectors/README.md`, `test/wire_vectors/{v1-dart,v1-kt,v2,edge}/` (`.frame` files + `checksums.txt` each)
- Create: `packages/gossip/test/wire_vectors/wire_vectors_test.dart`

**Interfaces:**
- Consumes: both codec facades with explicit versions.
- Produces: the Dart-canonical vector home (§11 decision 2). Fixture format = gossip-kt's proven pattern: raw frame bytes in `<name>.frame`, SHA-256 manifest in `checksums.txt`, a `regenerate` flag that deliberately fails the run when true. Scenario data is shared with kt's existing fixtures: nodes `node-a`/`node-b`/`node-c`, channels `ch-1`/`ch-2`, streams `st-1`/`st-2`, `Hlc(1_700_000_000_000 + seq, seq)`, payload bytes `[0, 1, 127, 128, 255]`.

Set contents (§8c):

| Set | Files | Pinned by |
|---|---|---|
| `v1-dart` | `ping`, `ack`, `pingreq` (`{sender:node-a, sequence:9, target:node-b}`), `digestrequest`, `digestresponse` (digests: ch-1/st-1, vv `{node-a:3, node-b:1}`), `deltarequest-1/2/3` (flat: ch-1/st-1 since `{node-a:2, node-b:0}`; ch-1/st-2 since `{node-a:1}`; ch-2/st-1 since `{node-b:3}`), `deltaresponse-1/2/3` (flat, entries matching kt's batched fixture, unsigned payloads), `deltaresponse-floor` (ch-1/st-1, entries `[entry(1)]`, `floor {node-a:2}` — the ruled v1+floor emission variant) | Dart v1 codecs encode byte-exact + decode→re-encode; translator suite (W-T2) |
| `v1-kt` | Byte-copies of gossip-kt's committed 7 fixtures (`ping`, `ack`, `pingreq`, `digestrequest`, `digestresponse`, `deltarequest`, `deltaresponse`) **plus three new Dart-authored frames**: `deltarequest-single` (wrap of deltarequest-1: `{"sender":"node-a","channelDeltas":{"ch-1":{"st-1":{"node-a":2,"node-b":0}}}}`), `deltaresponse-single` (wrap of deltaresponse-1, unsigned payload), `deltaresponse-floor` (`{"sender":"node-b","entries":{"ch-1":{"st-1":[entry(1)]}},"floor":{"ch-1":{"st-1":{"node-a":2}}}}`, unsigned payload — §7.4's per-(channel,stream) floor) | Checksums only in Dart (Dart never decodes v1-kt); kt vendors and pins encode/decode (W-K3/W-K4); translator suite |
| `v2` | 7 frames, `[0xF2][type][JSON]`: types 0–5 with v1-dart's values (pingreq = 3-key form per plan decision 2), `deltaresponse` = ch-1/st-1, entries `[entry(1), entry(2)]`, `hasMore: true`, `floor {node-a:2}`, payload `"AAF/gP8="` (base64 of `[0,1,127,128,255]`) | Both libraries' v2 codecs, byte-exact both directions |
| `edge` | `empty` (0 bytes), `reserved-07`, `reserved-80`, `marker-f0`, `marker-f1`, `marker-f3`, `escape-ff` (each `[byte, 0x01]`), `marker-only` (`[0xF2]`), `malformed-json` (`[3] + "not json"`), `v2-intlist-payload` (v2 DeltaResponse whose entry payload is `[1,2,3]` — MUST decode, §7.3 decoder grace), `v1-payload-signed` (v1 DeltaResponse with payload `[0,-1,-128]` — must DECODE, normalizing to `0,255,128`: this is the deployed kt server's emission), `v1-payload-out-of-range` (v1 DeltaResponse with payload `[300]` — outside −128..255, must be rejected), `v1-deltaresponse-defaults` (v1 DeltaResponse without `hasMore`/`floor` — decodes to `false`/empty) | Per-library behavior tests (frames shared; expected outcomes are library-local) |

- [ ] **Step 1: Copy the kt fixtures (byte-preserving)**

```bash
mkdir -p /Users/joel/git/neutrinographics/gossip/packages/gossip/test/wire_vectors/v1-kt
cp /Users/joel/git/neutrinographics/gossip-kt/src/test/resources/wire/v1-kt/*.frame \
   /Users/joel/git/neutrinographics/gossip/packages/gossip/test/wire_vectors/v1-kt/
# Verify byte-identity against kt's committed manifest before regenerating anything:
cd /Users/joel/git/neutrinographics/gossip/packages/gossip/test/wire_vectors/v1-kt && shasum -a 256 *.frame
diff <(shasum -a 256 *.frame | awk '{print $1"  "$2}' | sort) \
     <(sort /Users/joel/git/neutrinographics/gossip-kt/src/test/resources/wire/v1-kt/checksums.txt)
```

- [ ] **Step 2: Write `wire_vectors_test.dart`** — model it directly on kt's `V1WireGoldenTest` (regenerate-flag generator that throws so a regenerating build can never be green; `assertGolden` = encode byte-exact + decode→re-encode byte-exact; a checksums test per set). Structure:

```dart
// Sketch of the load-bearing parts; write the full file.
final fixtures = Directory('test/wire_vectors');
const regenerate = false; // set true ONCE to write fixtures, then revert.

final v1Sync = SyncMessageCodec(wireVersion: WireVersion.v1);
final v2Sync = SyncMessageCodec(wireVersion: WireVersion.v2);
final v1Membership = MembershipMessageCodec(wireVersion: WireVersion.v1);
final v2Membership = MembershipMessageCodec(wireVersion: WireVersion.v2);

// v1-dart and v2 vector maps: name -> ProtocolMessage, built from the
// shared scenario data above (LinkedHashMap ordering fixes JSON key order,
// exactly as kt's fixtures do). The v1-kt single/floor frames and every
// edge frame are hand-built JSON/bytes in the generator (Dart is the
// canonical author; kt must reproduce them).
// Generator (when regenerate) writes all .frame files + checksums.txt per
// set, then throws AssertionError('Wire fixtures regenerated...').

// Verification tests:
// - for each set: recomputed sha256 of each file == checksums.txt entry,
//   and the file list matches exactly.
// - v1-dart: assertGolden against v1Sync/v1Membership.
// - v2: assertGolden against v2Sync/v2Membership.
// - v1-kt: checksums only.
// - edge: expected behavior per frame, e.g.:
//     empty/marker-only/reserved/unassigned → both codecs throw ArgumentError;
//     malformed-json → sync codec throws (type 3 is sync's);
//     v2-intlist-payload → v1Sync.decode returns DeltaResponse with
//       payload [1,2,3] (decoder grace);
//     v1-payload-signed → decodes with bytes normalized to 0,255,128;
//     v1-payload-out-of-range → throws;
//     v1-deltaresponse-defaults → hasMore false, floor empty.
```

Use `dart:io` + `package:crypto` (already a dev dependency? verify `pubspec.yaml`; if absent add `crypto: ^3.0.0` to dev_dependencies) for SHA-256.

- [ ] **Step 3: Generate, review, lock.** Set `regenerate = true`, run `dart test test/wire_vectors/wire_vectors_test.dart` (fails by design), inspect every generated frame with `xxd`/`cat` against §7.2/§7.3/§7.4, set `regenerate = false`, re-run → all green. Confirm the 7 copied v1-kt frames were NOT rewritten (`git status` shows only additions; step-1 diff still holds).

- [ ] **Step 4: README.md** — document: Dart is the canonical home (§11 decision 2); consumers vendor byte-copies + manifests; updates are a deliberate re-copy + manifest regeneration, never automatic; encode checks are byte-exact (JSON: no whitespace, insertion-order keys — both `jsonEncode` and kotlinx `Json` comply); if a future vector cannot be byte-matched cross-language, the encode check for that vector may relax to "decodes equal + re-encodes canonically", recorded here.

- [ ] **Step 5: Full gate** — `dart test && dart analyze`.

- [ ] **Step 6: Commit**

```bash
git add test/wire_vectors pubspec.yaml
git commit -m "test(wire): canonical conformance vector sets (v1-dart, v1-kt, v2, edge)

v1-kt frames are byte-copies of gossip-kt's committed fixtures plus
three new Dart-authored frames (single-entry request/response and the
v1+floor variant); nothing pre-existing was regenerated.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task W-D7: Dart phase gate, CHANGELOG, PR

**Files:**
- Modify: `packages/gossip/CHANGELOG.md` (Unreleased section)

- [ ] **Step 1: Full verification**

```bash
cd /Users/joel/git/neutrinographics/gossip && melos run test && melos run analyze
cd packages/gossip && dart test | tail -3   # record final count; compare with W-D1 baseline + added tests
```

Confirm: no lost tests vs the recorded baseline; boundary_test green; transports (`gossip_nearby`, `gossip_bluey`) untouched and green (spec §10: no transport change).

- [ ] **Step 2: CHANGELOG (Unreleased)** — add: `wireVersion` on `CoordinatorConfig` (enum, default v1; receive always both); default emission is now the legacy v1 wire (unprefixed, int-array payloads, no hasMore, additive floor) — the unprefixed-base64 interim wire no longer exists; append-time payload cap under default config is now ~7.4KB (v1 sizing; set `wireVersion: v2` for ~22KB); conformance vectors under `test/wire_vectors/`.

- [ ] **Step 3: Commit and open the PR**

```bash
git add packages/gossip/CHANGELOG.md
git commit -m "docs: changelog for wire versioning

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push -u origin wire-versioning
gh pr create --base working-connection --title "Wire versioning: v2 marker, receive-both codecs, wireVersion config (default v1)" \
  --body "Implements docs/superpowers/specs/2026-08-28-wire-versioning.md steps 1 and the canonical vector home (step 3, Dart leg). Receive-both lands before any sender can flip; default stays v1.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Joel squash-merges; Phase W-K may proceed as soon as the vectors exist on the branch (kt vendors from the branch checkout).

---

# Phase W-K — gossip-kt, branch `feature/compaction`

### Task W-K1: kt marker table and `WireVersion`

**Files:**
- Modify: `src/main/kotlin/com/neutrinographics/gossip/shared/domain/values/WireTypes.kt`
- Create: `src/main/kotlin/com/neutrinographics/gossip/shared/domain/values/WireVersion.kt`
- Test: `src/test/kotlin/com/neutrinographics/gossip/shared/domain/values/WireTypesTest.kt` (extend the existing pin test)

**Interfaces:**
- Produces: `enum class WireVersion { V1, V2 }`; `WireTypes.MARKER_V2: Byte` (0xF2); `sealed interface FrameFraming { V1(typeByte) / V2(typeByte) / Undecodable(detail) }` (top-level in WireTypes.kt); `WireTypes.classifyFrame(data: ByteArray): FrameFraming` — `V1` for a known type byte at 0, `V2` for `0xF2` + known type byte at 1, `Undecodable` for empty frames, reserved bytes, unassigned/unregistered markers, `0xFF`, marker-without-type, and a v2 frame whose type byte is unknown.

- [ ] **Step 1: Record the kt baseline** — `./gradlew test` (expected 629; record the actual).
- [ ] **Step 2: Write the failing tests** (mirror W-D1's cases in kotlin.test style: marker value, classify v1/v2, the full Undecodable byte list including `[0xF2, 0x50]`).
- [ ] **Step 3: Implement**

```kotlin
enum class WireVersion { V1, V2 }
```

```kotlin
/** How a frame's leading byte(s) classify under the version-marker table. */
sealed interface FrameFraming {
    data class V1(val typeByte: Byte) : FrameFraming
    data class V2(val typeByte: Byte) : FrameFraming
    data class Undecodable(val detail: String) : FrameFraming
}

// inside object WireTypes:
    /** First byte of every v2 frame; version = byte - 0xF0. */
    const val MARKER_V2: Byte = 0xF2.toByte()

    fun classifyFrame(data: ByteArray): FrameFraming {
        if (data.isEmpty()) return FrameFraming.Undecodable("empty frame")
        val first = data[0]
        if (first in KNOWN) return FrameFraming.V1(first)
        if (first == MARKER_V2) {
            if (data.size < 2) return FrameFraming.Undecodable("version marker with no type byte")
            val type = data[1]
            return if (type in KNOWN) FrameFraming.V2(type)
            else FrameFraming.Undecodable("unknown v2 type byte: $type")
        }
        return FrameFraming.Undecodable("reserved or unregistered first byte: $first")
    }
```

Also delete the now-stale "Version markers are deliberately absent" sentence from the object's KDoc.
- [ ] **Step 4: Gate** — `./gradlew test`.
- [ ] **Step 5: Commit** — `feat(wire): v2 marker table and frame classification`

---

### Task W-K2: `DecodeResult` — reported decode failures replace the silent null

**Files:**
- Rewrite: `src/main/kotlin/com/neutrinographics/gossip/shared/domain/interfaces/MessageCodec.kt`
- Modify: `membership/infrastructure/MembershipMessageCodec.kt`, `sync/infrastructure/SyncMessageCodec.kt` (decode signatures only; sync stays batched in this task), `coordinator/Coordinator.kt:286-309`, `membership/domain/messages/PingReq.kt` (drop `originalRequester`), `membership/application/FailureDetector.kt` (`:321` read → `sender`, `:491` construction, plus the `decodeMessage` test helper)
- Test: `MembershipMessageCodecTest.kt`, `SyncMessageCodecTest.kt`, `CoordinatorTest` (or the closest existing coordinator test class), `wire/V1WireGoldenTest.kt` (helper only)

**Interfaces:**
- Produces (spec §6.2 — this is where kt's silent null dies):

```kotlin
/** Outcome of classifying and decoding one inbound frame. */
sealed interface DecodeResult {
    /**
     * Frames this codec owns, decoded. Usually one message; kt's v1
     * batched deltas fan out to several flat messages (from W-K3 on).
     */
    data class Decoded(val messages: List<ProtocolMessage>) : DecodeResult

    /** A well-formed frame owned by a sibling context. Routine, not an error. */
    data object NotMine : DecodeResult

    /**
     * A frame nobody can own: empty, reserved/unregistered first byte,
     * corrupt payload. The dispatcher must REPORT this — never drop it
     * silently.
     */
    data class Malformed(val detail: String, val cause: Throwable? = null) : DecodeResult
}

interface MessageCodec {
    fun encode(message: ProtocolMessage): ByteArray
    fun decode(data: ByteArray): DecodeResult
}
```

- [ ] **Step 1: Write the failing tests**
  - Codec tests: unknown first byte (`0x50`) → `Malformed`; sibling byte → `NotMine`; corrupt JSON of own family → `Malformed` with cause; own family → `Decoded` with one message; `[0xF2, pingByte, json]` decodes in the membership codec (`Decoded`) and answers `NotMine` in sync.
  - Coordinator test (this is the §6.2 pin):

```kotlin
@Test
fun `a malformed frame is reported once and the receive loop survives`() = runTest {
    // Build a coordinator with an InMemoryMessagePort and an onError
    // collector (mirror the existing coordinator test fixtures).
    // Send: byteArrayOf(0x50, 1, 2)   — reserved byte
    // Then: a valid encoded Ping.
    // Assert: exactly ONE PeerSyncError with type MESSAGE_CORRUPTED and
    // peer == the sending node was reported; the Ping was still routed
    // (an Ack came back on the port).
}
```

- [ ] **Step 2: Run to verify failure** — `./gradlew test --tests '*MessageCodecTest*'`.
- [ ] **Step 3: Implement.** Membership decode:

```kotlin
override fun decode(data: ByteArray): DecodeResult {
    val framing = WireTypes.classifyFrame(data)
    val typeByte = when (framing) {
        is FrameFraming.Undecodable -> return DecodeResult.Malformed(framing.detail)
        is FrameFraming.V1 -> framing.typeByte
        is FrameFraming.V2 -> framing.typeByte
    }
    if (typeByte !in WireTypes.MEMBERSHIP) return DecodeResult.NotMine
    val offset = if (framing is FrameFraming.V2) 2 else 1
    return try {
        val json = Json.parseToJsonElement(data.copyOfRange(offset, data.size).decodeToString()).jsonObject
        DecodeResult.Decoded(listOf(decodeMessageData(typeByte, json)!!))
    } catch (e: Exception) {
        DecodeResult.Malformed("corrupt ${'$'}typeByte frame: ${'$'}e", e)
    }
}
```

**`PingReq.originalRequester` is dropped from the domain (plan decision 2, spec §11 decision 4).** Three coordinated edits, all behavior-identical:

```kotlin
// membership/domain/messages/PingReq.kt — the field is deleted.
data class PingReq(
    override val sender: NodeId,
    val target: NodeId,
    val sequenceNumber: Int,
) : ProtocolMessage()
```

```kotlin
// FailureDetector.kt:491 — construction dropped the field it always set
// to localNode, which is already what `sender` carries.
// FailureDetector.kt:321 — the indirect-probe reply is addressed to
// `request.sender` instead of `request.originalRequester`; kt only ever
// produced requests where the two are the same value, and the deployed
// translator injects originalRequester = sender on every forwarded frame.
```

```kotlin
    // v1-kt emission keeps the deployed 4-key shape, sourcing the value
    // from the sender: the deployed server and every deployed app's
    // translator expect the key to be present.
    private fun encodePingReq(message: PingReq): JsonObject = buildJsonObject {
        put("sender", message.sender.value)
        put("sequence", message.sequenceNumber)
        put("target", message.target.value)
        put("originalRequester", message.sender.value)
    }

    // Decode ignores the key entirely — present (v1-kt) or absent (v2),
    // the answer goes back to the sender either way.
    private fun decodePingReq(json: JsonObject): PingReq = PingReq(
        sender = NodeId(json["sender"]!!.jsonPrimitive.content),
        target = NodeId(json["target"]!!.jsonPrimitive.content),
        sequenceNumber = json["sequence"]!!.jsonPrimitive.int,
    )
```

Tests: the `pingreq.frame` golden stays byte-identical (emission still carries the key, equal to `sender` — which is what the fixture already holds); a frame **without** `originalRequester` decodes to the same `PingReq`; a `FailureDetector` indirect-probe test pins that the ack goes to the requesting node.

Sync codec: same dispatch shape (family = `WireTypes.SYNC`); the body keeps today's batched `decodeMessageData` wrapped as `Decoded(listOf(...))`; a `FrameFraming.V2` sync frame answers `Malformed("v2 sync schema not yet registered")` **in this task only** (removed in W-K5; nothing emits v2 yet). Coordinator dispatch:

```kotlin
messagePort.incoming.collect { msg ->
    try {
        when (val result = decodeFrame(msg.data)) {
            is DecodeResult.Decoded ->
                result.messages.forEach { routeMessage(it, msg.data.size) }
            is DecodeResult.Malformed -> onError?.invoke(
                PeerSyncError(
                    peer = msg.sender,
                    type = SyncErrorType.MESSAGE_CORRUPTED,
                    message = "Malformed frame from ${'$'}{msg.sender.value}: ${'$'}{result.detail}",
                    occurredAt = Instant.now(),
                    cause = result.cause,
                ),
            )
            DecodeResult.NotMine -> onError?.invoke( // both codecs disowned it
                PeerSyncError(
                    peer = msg.sender,
                    type = SyncErrorType.MESSAGE_CORRUPTED,
                    message = "Frame from ${'$'}{msg.sender.value} owned by no codec",
                    occurredAt = Instant.now(),
                ),
            )
        }
    } catch (e: Exception) { /* existing StorageSyncError catch unchanged */ }
}

private fun decodeFrame(data: ByteArray): DecodeResult {
    val result = membershipCodec.decode(data)
    return if (result is DecodeResult.NotMine) syncCodec.decode(data) else result
}
```

Update `FailureDetector.decodeMessage` (test-only wrapper) and `V1WireGoldenTest.decodeFrame` to unwrap `Decoded`.
- [ ] **Step 4: Gate** — `./gradlew test` (all 7 golden fixtures still green, byte-identical).
- [ ] **Step 5: Commit** — `feat(wire): decode outcomes replace the silent null; malformed frames are reported` with a body noting that `PingReq.originalRequester` left the domain model (the detector reads `sender`; v1 emission still writes the key) and that the `pingreq` golden is unchanged.

---

### Task W-K3: Flat delta domain messages; v1 codec maps the batched wire

**Files:**
- Rewrite: `sync/domain/messages/DeltaRequest.kt`, `sync/domain/messages/DeltaResponse.kt`
- Create: `sync/infrastructure/SyncWireV1.kt` (batched-wire module; most of today's `SyncMessageCodec` encode/decode helpers move here)
- Modify: `sync/infrastructure/SyncMessageCodec.kt` (facade delegates v1 frames to `SyncWireV1`), `sync/application/GossipEngine.kt` (`computeAndSendDeltaRequests`, `handleDeltaRequest`, `handleDeltaResponse`, `logOutgoing`)
- Copy in: `src/test/resources/wire/v1-kt/deltarequest-single.frame`, `deltaresponse-single.frame` (vendored from the Dart canonical home) + regenerate `checksums.txt` to include them (existing 7 lines unchanged)
- Test: `SyncMessageCodecTest.kt`, `wire/V1WireGoldenTest.kt`, `sync/GossipEngineTest` (existing engine test class — update construction of delta messages throughout)

**Interfaces (spec §6.1 — domain convergence on Dart's flat shape):**

```kotlin
data class DeltaRequest(
    override val sender: NodeId,
    val channelId: ChannelId,
    val streamId: StreamId,
    val since: VersionVector,
) : ProtocolMessage()

data class DeltaResponse(
    override val sender: NodeId,
    val channelId: ChannelId,
    val streamId: StreamId,
    val entries: List<LogEntry>,
    val hasMore: Boolean = false,
    val floor: VersionVector = VersionVector.EMPTY,
) : ProtocolMessage()
```

`SyncWireV1` maps flat domain ↔ batched wire: **encode** wraps one flat message as a single-entry batched envelope (`{"sender":…,"channelDeltas":{ch:{st:vv}}}` / `{"sender":…,"entries":{ch:{st:[…]}}}`) — exactly the shape the deployed app's translator produces today, so it is proven-compatible with every deployed receiver; **decode** fans a batched frame out to one flat message per (channel, stream). Payload emission normalizes to unsigned 0–255 (`JsonPrimitive(it.toInt() and 0xFF)` — plan decision 1a); payload decode accepts −128..255 and rejects anything outside (decision 1b).

- [ ] **Step 1: Vendor the single-entry fixtures**

```bash
cp /Users/joel/git/neutrinographics/gossip/packages/gossip/test/wire_vectors/v1-kt/deltarequest-single.frame \
   /Users/joel/git/neutrinographics/gossip/packages/gossip/test/wire_vectors/v1-kt/deltaresponse-single.frame \
   /Users/joel/git/neutrinographics/gossip-kt/src/test/resources/wire/v1-kt/
```

- [ ] **Step 2: Write the failing tests.** In `V1WireGoldenTest`: the multi-entry `deltarequest`/`deltaresponse` fixtures become **decode-only** (encode can no longer produce multi-stream envelopes — disclosed in the commit):

```kotlin
@Test
fun `batched DeltaRequest golden fans out to three flat requests`() {
    val golden = File(fixtures, "deltarequest.frame").readBytes()
    val decoded = (syncCodec.decode(golden) as DecodeResult.Decoded).messages
        .map { it as DeltaRequest }
    assertEquals(3, decoded.size)
    assertEquals(ChannelId("ch-1") to StreamId("st-1"), decoded[0].channelId to decoded[0].streamId)
    assertEquals(2, decoded[0].since.entries[NodeId("node-a")])
    assertEquals(0, decoded[0].since.entries[NodeId("node-b")])
    // ... pins for decoded[1] (ch-1/st-2) and decoded[2] (ch-2/st-1)
}

@Test
fun `flat DeltaRequest encodes to the canonical single-entry envelope`() {
    val golden = File(fixtures, "deltarequest-single.frame").readBytes()
    val flat = DeltaRequest(
        sender = nodeA, channelId = channel, streamId = stream,
        since = VersionVector(linkedMapOf(nodeA to 2, nodeB to 0)),
    )
    assertContentEquals(golden, syncCodec.encode(flat))
}
// Same pair for DeltaResponse: batched golden fans out to three flat
// responses (payload bytes decode to 0x00,0x01,0x7F,0x80,0xFF from the
// SIGNED fixture ints); flat response encodes byte-exact to
// deltaresponse-single.frame (UNSIGNED ints — emission normalized).
```

Plus codec tests: payload int 300 → `Malformed`; payload −1 decodes to 0xFF.

- [ ] **Step 3: Run to verify failure**, then implement the messages, `SyncWireV1`, the facade delegation, and the engine changes:

```kotlin
// computeAndSendDeltaRequests — the accumulation map disappears:
if (!ourVersion.dominates(streamDigest.versionVector)) {
    _pendingDeltaRequests[key] = timePort.nowMs
    sendMessage(peer, DeltaRequest(localNode, channelId, streamDigest.streamId, ourVersion))
}

// handleDeltaRequest — per-stream:
private suspend fun handleDeltaRequest(request: DeltaRequest) {
    val entries = entryRepository.entriesSince(request.channelId, request.streamId, request.since)
    if (entries.isEmpty()) return   // floor handling arrives in W-K4
    sendMessage(
        request.sender,
        DeltaResponse(
            sender = localNode,
            channelId = request.channelId,
            streamId = request.streamId,
            entries = entries,
        ),
    )
}

// handleDeltaResponse — flat merge (same steps as today, un-nested):
private suspend fun handleDeltaResponse(response: DeltaResponse) {
    if (response.entries.isEmpty()) return
    _pendingDeltaRequests.remove(response.channelId to response.streamId)
    updateHlcFromEntries(response.entries)
    val previousTail = entryRepository.getTailTimestamp(response.channelId, response.streamId)
    entryRepository.appendAll(response.channelId, response.streamId, response.entries)
    val containsOutOfOrder = previousTail != null &&
        response.entries.any { it.timestamp < previousTail }
    onEntriesMerged?.invoke(response.channelId, response.streamId, response.entries, containsOutOfOrder)
    peerService.recordPeerAntiEntropy(response.sender, timePort.nowMs)
}
```

Update `logOutgoing`'s DeltaRequest/DeltaResponse branches to log `channelId/streamId`. Update every engine/coordinator test constructing batched messages to the flat shape.
- [ ] **Step 4: Gate** — `./gradlew test`. Original 7 fixture files untouched (`git status` under `src/test/resources` shows only the two new frames + extended checksums).
- [ ] **Step 5: Commit** — `refactor(sync): flat per-stream delta messages; v1 codec maps the batched wire` with body disclosing: multi-entry delta goldens are now decode-only pins; two vendored single-entry frames added; v1 payload emission normalized to unsigned 0-255 (accepted range on decode unchanged at -128..255).

---

### Task W-K4: Floor and `hasMore` semantics on the kt delta path

**Files:**
- Modify: `sync/application/GossipEngine.kt`, `sync/infrastructure/SyncWireV1.kt`
- Copy in: `src/test/resources/wire/v1-kt/deltaresponse-floor.frame` (vendored from Dart canonical) + extend `checksums.txt`
- Test: `sync/GossipEngineTest` (new cases), `V1WireGoldenTest.kt`

**Interfaces:**
- Consumes: `EntryRepository.getCompactionFloor`, `EntryRepository.adoptVersionFloor` (exists, currently uncalled — this task wires it), `VersionVector.EMPTY`.
- Produces: responder emits the reportable floor; requester adopts a solicited floor and follows a truthful `hasMore` with a continuation request. `SyncWireV1` carries `floor` as `{"floor":{ch:{st:vv}}}` alongside `entries` (§7.4, §11 decision 3), emitting it only when non-empty and fanning it out per stream on decode.

- [ ] **Step 1: Write the failing tests**
  - Golden: flat `DeltaResponse(entries=[entry(1)], floor={node-a:2})` for ch-1/st-1 encodes byte-exact to the vendored `deltaresponse-floor.frame`; decoding that frame yields one flat response with `floor.entries == {node-a: 2}`.
  - Engine: (a) responder whose repository floor is `{node-a:5}` answering a request with `since={node-a:2}` sends `floor={node-a:5}` (and answers even when `entriesSince` is empty); a requester already at `since={node-a:7}` gets an empty floor. (b) a **solicited** response (pending request present) with a floor calls `adoptVersionFloor` before the merge; an unsolicited one must not. (c) a response with `hasMore = true` and merged entries triggers exactly one continuation `DeltaRequest` with the post-merge version vector; `hasMore = false` triggers none.
- [ ] **Step 2: Verify failure**, then implement:

```kotlin
private suspend fun handleDeltaRequest(request: DeltaRequest) {
    val entries = entryRepository.entriesSince(request.channelId, request.streamId, request.since)
    val floor = reportableFloor(request)
    if (entries.isEmpty() && floor.entries.isEmpty()) return
    sendMessage(
        request.sender,
        DeltaResponse(
            sender = localNode,
            channelId = request.channelId,
            streamId = request.streamId,
            entries = entries,
            hasMore = false, // kt sends complete deltas; no pagination yet
            floor = floor,
        ),
    )
}

/**
 * The portion of our compaction floor the requester is still behind —
 * a requester positioned below it asked for entries retention pruned
 * away; reporting the floor lets it adopt truncated history instead of
 * re-requesting the same gap forever.
 */
private suspend fun reportableFloor(request: DeltaRequest): VersionVector {
    val fullFloor = entryRepository.getCompactionFloor(request.channelId, request.streamId)
    if (fullFloor.entries.isEmpty()) return VersionVector.EMPTY
    val belowFloor = fullFloor.entries.filter { (author, seq) ->
        (request.since.entries[author] ?: 0) < seq
    }
    return if (belowFloor.isEmpty()) VersionVector.EMPTY else VersionVector(belowFloor)
}

private suspend fun handleDeltaResponse(response: DeltaResponse) {
    val key = response.channelId to response.streamId
    val solicited = _pendingDeltaRequests.containsKey(key)
    _pendingDeltaRequests.remove(key)

    // Only a response we asked for can move our floor: the sender's own
    // claim of being solicited cannot be trusted.
    if (solicited && response.floor.entries.isNotEmpty()) {
        entryRepository.adoptVersionFloor(response.channelId, response.streamId, response.floor)
    }
    if (response.entries.isEmpty()) return

    updateHlcFromEntries(response.entries)
    val previousTail = entryRepository.getTailTimestamp(response.channelId, response.streamId)
    entryRepository.appendAll(response.channelId, response.streamId, response.entries)
    val containsOutOfOrder = previousTail != null &&
        response.entries.any { it.timestamp < previousTail }
    onEntriesMerged?.invoke(response.channelId, response.streamId, response.entries, containsOutOfOrder)
    peerService.recordPeerAntiEntropy(response.sender, timePort.nowMs)

    // A truncating (v2 Dart) responder signals continuation; drain at
    // link speed instead of one page per periodic round. Progress-gated
    // to prevent an infinite loop against a stuck responder.
    if (response.hasMore) {
        val updated = entryRepository.getVersionVector(response.channelId, response.streamId)
        _pendingDeltaRequests[key] = timePort.nowMs
        sendMessage(response.sender, DeltaRequest(localNode, response.channelId, response.streamId, updated))
    }
}
```

`SyncWireV1` floor encode/decode: emit `"floor" to JsonObject(mapOf(ch to JsonObject(mapOf(st to encodeVersionVector(msg.floor)))))` when non-empty; on decode, look up `json["floor"]?.jsonObject?.get(channelKey)?.jsonObject?.get(streamKey)` per fanned-out stream, defaulting `VersionVector.EMPTY`.
- [ ] **Step 3: Gate** — `./gradlew test`.
- [ ] **Step 4: Commit** — `feat(sync): compaction floor and hasMore continuation on the delta path`

---

### Task W-K5: kt v2 codec module and `wireVersion` config

**Files:**
- Create: `sync/infrastructure/SyncWireV2.kt`
- Modify: `sync/infrastructure/SyncMessageCodec.kt` (facade: `class SyncMessageCodec(private val wireVersion: WireVersion)`; encode → active module; `FrameFraming.V2` sync frames → `SyncWireV2.decode`, removing W-K2's placeholder `Malformed`), `membership/infrastructure/MembershipMessageCodec.kt` (`wireVersion` constructor param; v2 encode = `[0xF2, type] + identical JSON`, except PingReq's v2 form omits the `originalRequester` key the v1 module still writes — plan decision 2), `coordinator/CoordinatorConfig.kt`, `coordinator/Coordinator.kt:173-175`
- Test: `SyncMessageCodecTest.kt`, `MembershipMessageCodecTest.kt`, config test

**Interfaces:**
- Produces: `SyncWireV2` — flat schemas per §7.3, byte-identical to Dart's v2 emission: key order `sender, channelId, streamId, entries, hasMore, [floor]`; entry order `author, sequence, timestamp{physicalMs, logical}, payload`; payload = `java.util.Base64.getEncoder().encodeToString(entry.payload)`; decode accepts base64 AND the legacy int list (0–255 only — §7.3 decoder grace), defaults `hasMore=false`/`floor=EMPTY`, decodes to ONE flat message (`Decoded(listOf(...))`). `CoordinatorConfig.wireVersion: WireVersion = WireVersion.V1` (§11 decision 1: default v1; the deployed server flips at deploy time, not via a library default).

- [ ] **Step 1: Write the failing tests** — v2 round-trips for all 7 types; v2 DeltaResponse emission key-order/byte assertions (`bytes[0] == 0xF2`, JSON string equality against a hand-written literal); v2 PingReq emits exactly `{"sender":…,"sequence":…,"target":…}` (the field left the domain in W-K2; v1 emission still writes it from `sender`); v2 int-list grace decodes and out-of-range rejects; config default test `assertEquals(WireVersion.V1, CoordinatorConfig().wireVersion)`; coordinator wiring test: config v2 → outgoing frames start with `0xF2` (use the InMemory port, mirror the Dart W-D4 test).
- [ ] **Step 2: Verify failure, implement.** Facade encode:

```kotlin
override fun encode(message: ProtocolMessage): ByteArray = when (wireVersion) {
    WireVersion.V1 -> SyncWireV1.encode(message)
    WireVersion.V2 -> SyncWireV2.encode(message)
}
```

Coordinator: `SyncMessageCodec(wireVersion = config.wireVersion)`, `MembershipMessageCodec(wireVersion = config.wireVersion)`; update all test construction sites with explicit versions (existing behavior pins choose `WireVersion.V1` — kt's suite pins the deployed wire).
- [ ] **Step 3: Gate** — `./gradlew test` (V1WireGoldenTest untouched and green).
- [ ] **Step 4: Commit** — `feat(wire): v2 codec modules behind a wireVersion config, default v1`

---

### Task W-K6: Vendored v2/edge vectors, behavior-pinned, under the EXISTING checksum test

*(Revised 2026-08-29: the checksum-manifest test this task used to propose
creating **already exists** — `V1WireGoldenTest.kt:180-190`, "every fixture
matches its recorded checksum", shipped with the v1-kt fixtures: it reads
`checksums.txt`, asserts the recorded filename set equals the vector set, and
SHA-256s each `.frame`. This task therefore **extends that test's coverage to
the newly vendored `v2/` and `edge/` sets** — one manifest per set, the same
assertions — instead of building parallel machinery. Note its precise power:
the manifest catches a fixture mutated without a manifest update, but not a
wholesale regeneration of both together, so reviewer discipline on the diff
stays the defence there.)*

**Files:**
- Create: `src/test/resources/wire/v2/` and `src/test/resources/wire/edge/` (byte-copies + `checksums.txt` from the Dart canonical home)
- Modify: `src/test/kotlin/com/neutrinographics/gossip/wire/V1WireGoldenTest.kt` — generalize the existing checksum test over the three vendored sets (`v1-kt`, `v2`, `edge`); rename the class only if its scope no longer reads honestly
- Create: `src/test/kotlin/com/neutrinographics/gossip/wire/WireVectorConformanceTest.kt` — the v2/edge **behavior** pins (semantics + byte-exact re-encode), not checksums

**Interfaces:**
- Consumes: both facades (explicit versions), `DecodeResult`.
- Per §11 decision 2, the drift test recomputes SHA-256 over the locally vendored copies and compares against the committed manifest — drift between the repos fails the kt build. Updates are a deliberate re-copy + manifest re-commit, never automatic.

- [ ] **Step 1: Vendor**

```bash
CANON=/Users/joel/git/neutrinographics/gossip/packages/gossip/test/wire_vectors
mkdir -p src/test/resources/wire/v2 src/test/resources/wire/edge
cp $CANON/v2/*.frame $CANON/v2/checksums.txt src/test/resources/wire/v2/
cp $CANON/edge/*.frame $CANON/edge/checksums.txt src/test/resources/wire/edge/
```

- [ ] **Step 2: Extend the existing checksum test** (`V1WireGoldenTest.kt:180-190`) from one hard-coded fixture directory to the three vendored sets (`v1-kt`, `v2`, `edge`), keeping its two assertions per set: recorded filename set == actual file set, and each file's SHA-256 == its manifest line.
- [ ] **Step 3: Write the failing behavior test** covering: (a) each v2 vector decodes to the expected semantics and re-encodes byte-exact through the matching v2 codec (`membership` for types 0–2, `sync` for 3–6); (b) edge behaviors: `empty`/`marker-only`/`reserved-*`/`marker-f0/f1/f3`/`escape-ff` → `Malformed` from both codecs; `malformed-json` → `Malformed`; `v2-intlist-payload` → `Decoded` with payload `[1,2,3]`; `v1-payload-out-of-range` (an element outside −128..255) → `Malformed`, while `v1-payload-signed` decodes with its negative elements normalized (plan decision 1b); `v1-deltaresponse-defaults` → flat response with `hasMore=false`, empty floor. Note kt reports Malformed once at the coordinator (single dispatch site) where Dart reports twice (two subscriptions) — both satisfy §4 rule 4.
- [ ] **Step 4: Gate** — `./gradlew test`. Record the final kt count (expected ≈629 baseline + ~55).
- [ ] **Step 5: Commit** — `test(wire): vendored v2 and edge conformance vectors under the existing checksum pin`

---

# Phase W-T — OpenDoorApp, branch `wire-floor-translation`

### Task W-T2: Translator floor mapping, payload normalization, v2 passthrough — pinned against the vectors

*(Revised 2026-08-29: the separate vendoring task W-T1 is collapsed into this
one. The translator suite does not vendor the Dart-side vector set and grows
no manifest/checksum machinery. **Dart-side frames are produced by the real
codec** from the `gossip` library dependency the app already ships — that
dependency IS the app's Dart dialect, so a frame it encodes cannot drift from
the library under test — and the v1-kt frames are **plain byte-copies** of
gossip-kt's committed goldens carrying a provenance comment naming their
source path and commit. The rationale for skipping the checksum apparatus:
this suite exists only for the migration window, and the translator it pins
is deleted at v2 (spec §5.3 step 8); cross-repo drift protection is worth its
weight between the two long-lived libraries, not around a shim with a known
death date. Cross-repo checksum pinning therefore scopes to the two libraries
only — see R1 step 2.)*

**Files:**
- Modify: `lib/features/sync/infrastructure/gossip/protocol_translator.dart`
- Create: `test/features/sync/infrastructure/gossip/wire_vectors/v1-kt/` — plain byte-copies of the v1-kt frames (the 7 gossip-kt originals + `deltarequest-single`, `deltaresponse-single`, `deltaresponse-floor`), no `checksums.txt`, with a `README.md` recording where they came from and that re-copying is a deliberate act
- Test: `test/features/sync/infrastructure/gossip/protocol_translator_test.dart` (extend the existing suite)

**Interfaces:**
- Produces (§11 consequence + §8c set 3): `translateOutgoing` carries `floor` across the flat→batched reshape; `translateIncoming` fans a batched `floor` out per stream (including floor-only streams with no entries), normalizes signed payload ints (plan decision 1c), and passes `0xF2`-prefixed frames through untouched (already structurally true via the `default:` branch — this task pins it).

- [ ] **Step 0: Branch, baseline, vendor**

```bash
cd /Users/joel/git/neutrinographics/OpenDoorApp
git checkout main && git pull && git checkout -b wire-floor-translation
flutter test test/features/sync 2>&1 | tail -2   # record the count
```

Copy the ten v1-kt `.frame` files from the Dart canonical home into
`test/.../wire_vectors/v1-kt/` and write the provenance README. Do **not**
copy the `v1-dart` set: the Dart-side expectations in step 1 are encoded on
the fly by `SyncMessageCodec(wireVersion: WireVersion.v1)` /
`MembershipMessageCodec(wireVersion: WireVersion.v1)` from the app's `gossip`
dependency.

- [ ] **Step 1: Write the failing tests.** Two helpers: `Uint8List ktFrame(String name)` reads a vendored file, and `Uint8List dartFrame(String name)` looks the name up in a small table of scenario messages (the same scenario data the canonical vectors use — nodes `node-a`/`node-b`, channels `ch-1`/`ch-2`, streams `st-1`/`st-2`) and encodes it through the library's v1 codec. The round-trips below are written against those two.

```dart
group('vector round-trips', () {
  test('outgoing flat delta request wraps to the canonical batched frame', () {
    expect(
      translator.translateOutgoing(dartFrame('deltarequest-1')),
      equals(ktFrame('deltarequest-single')),
    );
  });

  test('outgoing flat delta response wraps to the canonical batched frame', () {
    expect(
      translator.translateOutgoing(dartFrame('deltaresponse-1')),
      equals(ktFrame('deltaresponse-single')),
    );
  });

  test('outgoing floor crosses the reshape into the batched floor map', () {
    expect(
      translator.translateOutgoing(dartFrame('deltaresponse-floor')),
      equals(ktFrame('deltaresponse-floor')),
    );
  });

  test('incoming batched request fans out to the three flat frames', () {
    expect(
      translator.translateIncoming(ktFrame('deltarequest')),
      equals([
        dartFrame('deltarequest-1'),
        dartFrame('deltarequest-2'),
        dartFrame('deltarequest-3'),
      ]),
    );
  });

  test('incoming batched response fans out with payload ints normalized '
      'to 0-255', () {
    expect(
      translator.translateIncoming(ktFrame('deltaresponse')),
      equals([
        dartFrame('deltaresponse-1'),
        dartFrame('deltaresponse-2'),
        dartFrame('deltaresponse-3'),
      ]),
    );
  });

  test('incoming floor fans out onto the matching flat frame', () {
    expect(
      translator.translateIncoming(ktFrame('deltaresponse-floor')),
      equals([dartFrame('deltaresponse-floor')]),
    );
  });

  test('incoming pingreq drops originalRequester byte-exactly', () {
    expect(
      translator.translateIncoming(ktFrame('pingreq')),
      equals([dartFrame('pingreq')]),
    );
  });

  test('ping, ack and digests pass through unchanged in both directions', () {
    for (final name in ['ping', 'ack', 'digestrequest', 'digestresponse']) {
      final dart = frame('v1-dart', name);
      expect(translator.translateOutgoing(dart), equals(frame('v1-kt', name)));
      expect(translator.translateIncoming(frame('v1-kt', name)), equals([dart]));
    }
  });

  test('prefixed v2 frames pass through untouched in both directions', () {
    final v2Frame = Uint8List.fromList([0xF2, 6, ...utf8.encode('{"x":1}')]);
    expect(translator.translateOutgoing(v2Frame), equals(v2Frame));
    expect(translator.translateIncoming(v2Frame), equals([v2Frame]));
  });

  test('a floor for a fully-compacted stream survives fan-out even with '
      'no entries key for that stream', () {
    // Hand-built batched frame: entries {} but floor {ch-1:{st-1:{node-a:2}}}
    // → one flat frame with entries [] and floor {node-a:2}.
  });
});
```

- [ ] **Step 2: Run to verify failure** — `flutter test test/features/sync/infrastructure/gossip/protocol_translator_test.dart`.
- [ ] **Step 3: Implement** (full replacement bodies):

```dart
  Uint8List _translateOutgoingDeltaResponse(Uint8List bytes) {
    final payload = _decodePayload(bytes);
    final channelId = payload.remove('channelId') as String;
    final streamId = payload.remove('streamId') as String;
    final entries = payload.remove('entries');
    final floor = payload.remove('floor');
    payload['entries'] = {
      channelId: {streamId: entries},
    };
    if (floor != null) {
      payload['floor'] = {
        channelId: {streamId: floor},
      };
    }
    return _encode(_deltaResponse, payload);
  }

  List<Uint8List> _translateIncomingDeltaResponse(Uint8List bytes) {
    final payload = _decodePayload(bytes);
    final sender = payload['sender'];
    final entries = payload['entries'] as Map<String, dynamic>? ?? {};
    final floors = payload['floor'] as Map<String, dynamic>? ?? {};
    final results = <Uint8List>[];
    final covered = <String>{};

    for (final channelEntry in entries.entries) {
      final channelId = channelEntry.key;
      final streams = channelEntry.value as Map<String, dynamic>;
      for (final streamEntry in streams.entries) {
        covered.add('$channelId\u0000${streamEntry.key}');
        final flat = <String, dynamic>{
          'sender': sender,
          'channelId': channelId,
          'streamId': streamEntry.key,
          'entries': _normalizeEntries(streamEntry.value as List),
        };
        final floor =
            (floors[channelId] as Map<String, dynamic>?)?[streamEntry.key];
        if (floor != null) flat['floor'] = floor;
        results.add(_encode(_deltaResponse, flat));
      }
    }

    // A floor for a stream the sender no longer holds entries for must
    // still reach the requester: it is the only cure for a fully
    // compacted-away history.
    for (final channelEntry in floors.entries) {
      final streams = channelEntry.value as Map<String, dynamic>;
      for (final streamEntry in streams.entries) {
        if (covered.contains('${channelEntry.key}\u0000${streamEntry.key}')) {
          continue;
        }
        results.add(
          _encode(_deltaResponse, {
            'sender': sender,
            'channelId': channelEntry.key,
            'streamId': streamEntry.key,
            'entries': const [],
            'floor': streamEntry.value,
          }),
        );
      }
    }
    return results;
  }

  /// The Kotlin server's legacy wire encodes payload bytes as SIGNED
  /// JSON ints (-128..127); the upgraded Dart library rejects negatives
  /// as corruption. Reinterpret them as unsigned byte values here, where
  /// dialect bridging lives, so an upgraded app keeps decoding a
  /// not-yet-upgraded server.
  List<dynamic> _normalizeEntries(List<dynamic> entries) {
    return entries.map((e) {
      final entry = Map<String, dynamic>.from(e as Map<String, dynamic>);
      final payload = entry['payload'];
      if (payload is List) {
        entry['payload'] = [
          for (final b in payload) (b is int && b < 0) ? b + 256 : b,
        ];
      }
      return entry;
    }).toList();
  }
```

(`_translateOutgoingDeltaRequest` / `_translateIncomingDeltaRequest` / PingReq paths are unchanged.)
- [ ] **Step 4: Gate** — `flutter test test/features/sync` (all pre-existing translator tests still green).
- [ ] **Step 5: Commit** — `sync: carry the compaction floor across the protocol translator` with a body noting the signed-payload normalization and the v2 passthrough pin.

---

### Task W-T3: App phase gate and PR

- [ ] **Step 1:** `flutter test test/features/sync && flutter analyze lib/features/sync test/features/sync` — record final count vs the W-T2 step-0 baseline.
- [ ] **Step 2:** Push and open the PR to `main`:

```bash
git push -u origin wire-floor-translation
gh pr create --base main --title "Carry the gossip compaction floor across the protocol translator" \
  --body "Adds the floor field mapping (both directions) to ProtocolTranslator, normalizes the server's signed payload ints, pins v2-frame passthrough, and pins the whole shim against the vendored v1-dart/v1-kt conformance vectors.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

# Task R1: Rollout Readiness — the §5.3 step-3 gate

**This is verification only; it changes no code.**

- [ ] **Step 1: All three suites green, counted**

```bash
cd /Users/joel/git/neutrinographics/gossip && melos run test && melos run analyze
cd /Users/joel/git/neutrinographics/gossip-kt && ./gradlew test
cd /Users/joel/git/neutrinographics/OpenDoorApp && flutter test test/features/sync
```

- [ ] **Step 2: Every vector set passes in every consumer — and the vendored copies cannot have drifted**

The manifest gate scopes to **the two libraries only**. The app's translator suite is deliberately outside it (W-T2): it encodes its Dart-side frames with the real library codec it depends on, and its v1-kt copies are plain files with a provenance note, because the shim is deleted at v2 (§5.3 step 8) and does not warrant permanent drift machinery.

```bash
CANON=/Users/joel/git/neutrinographics/gossip/packages/gossip/test/wire_vectors
for d in v1-kt v2 edge; do
  diff "$CANON/$d/checksums.txt" \
       "/Users/joel/git/neutrinographics/gossip-kt/src/test/resources/wire/$d/checksums.txt" && echo "kt/$d OK"
done
```

(kt's vendored `v1-kt` manifest is a superset check: its original 7 lines must match the canonical manifest's corresponding lines byte-for-byte.)

- [ ] **Step 3: Confirm the gate and record it.** With steps 1–2 green, spec §5.3 step 3 is satisfied: the vectors prove receive-both holds in both libraries and the translator suite pins the shim against both v1 dialects. Record in the plan-execution notes: **"§5.3 step-3 gate GREEN on <date>: no sender may flip to v2 before this point; after it, flips remain deployment acts."**

- [ ] **Step 4: State what remains OWNER-ONLY.** Spec §5.3 steps 4–8 are deployment, not this campaign's to execute, and this plan performs none of them:
  - Step 4: bump the opendoor-api submodule to the new gossip-kt and deploy (server still v1-send).
  - Step 5: ship the app with the new Dart library (still v1-send, translator kept).
  - Step 6: flip the app fleet's `wireVersion` to v2 — only after the WHOLE fleet is upgraded.
  - Step 7: flip the server to v2-send — only after every served app passed step 5.
  - Step 8: delete `ProtocolTranslator` and retire kt's v1 module.
  Also owner-deferred (§11 decision 1): whether the library default itself ever flips to v2 (a ≥3.0.0 pub.dev publish decision).

---

## Spec coverage map (self-review record)

| Spec section | Where implemented |
|---|---|
| §2 version model / interim wire dies | W-D2 (v1/v2 emission modules; no unprefixed-base64 path remains), W-D4 (default v1) |
| §3.3 marker table | W-D1, W-K1 |
| §4 receive rules + Dart dispatch shape + double-codec constraint | W-D2/W-D3 (sibling-null per version), W-D4 (once-handled, zero-error integration test), W-K2 |
| §5.1 config enum, default v1 both | W-D4, W-K5 |
| §5.2 receivers before senders | task ordering + Global Constraints + R1 |
| §5.3 steps 1–3 | Phases W-D, W-K, W-T + R1; steps 4–8 recorded owner-only in R1 |
| §6.1 kt domain convergence, v1-kt stays live | W-K3 (flat messages, batched mapping), W-K4 (floor/hasMore), W-K5 (v2 module) |
| §6.2 reported decode failures | W-K2 |
| §7.2 v1-dart schemas + v1+floor emission + degradation test | W-D2, W-D5, W-D6 |
| §7.3 v2 schemas + decoder grace | W-D2 (kept decoders), W-K5, W-D6/W-K6 (`v2-intlist-payload` vector) |
| §7.4 v1-kt schemas + batched floor | W-K3, W-K4, W-D6 (canonical frames) |
| §8a modules per version | W-D2/W-K5 (see plan decision 3 for the Dart decode-sharing deviation) |
| §8b prose spec amendment | Amended 2026-08-29 before this batch runs: §7.1 integer width, §7.2/§7.4 payload signedness, §7.4 domain-model note, §8c negative vectors, §10 kt-budgeting reassignment, §11 decision 4 |
| §8c four vector sets + negatives + kt vendoring | W-D6, W-K6, W-T2 (set 3 without vendored Dart frames — see the task note) |
| §10 budget-from-active-codec (Dart) / kt budgeting reassigned post-KT-B | W-D2 (`encodedEntrySize`, `maxEntryPayloadForBudget(budget, version)`), plan decisions 4 and 5 |
| §11 decisions 1–4 | W-D4/W-K5 (enum default), W-D6/W-K6 (vendoring + manifests, libraries only), W-D2/W-K4/W-T2 (v1+floor; hasMore v2-only), W-K2/W-K5 (PingReq `originalRequester` dropped) |
