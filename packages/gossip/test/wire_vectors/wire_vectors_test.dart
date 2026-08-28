// Canonical wire conformance vectors — the Dart-side home for §8c of
// the wire-versioning spec (Dart is the canonical author; gossip-kt
// vendors byte-copies with a checksum-pinned sync test).
//
// Four sets on disk under test/wire_vectors/:
//   v1-dart  — Dart's v1 (unprefixed) dialect, round-tripped through the
//              real v1 codecs.
//   v1-kt    — the deployed server's batched v1 dialect. The 10 pre-
//              existing frames are byte-copies of gossip-kt's own
//              committed goldens (never rewritten here); 3 more are
//              Dart-authored, hand-built JSON matching that dialect,
//              since no Dart codec understands the batched shape.
//              Checksums only — Dart never decodes this dialect.
//   v2       — the prefixed dialect, round-tripped through the real v2
//              codecs.
//   edge     — negative and boundary-condition frames: unknown markers,
//              reserved bytes, malformed payloads, decoder-grace cases.
//
// Model: gossip-kt's V1WireGoldenTest. A `regenerate` flag drives a
// generator that writes every fixture file and then deliberately throws,
// so a regenerating build can never be green; verification tests check
// each set's encode/decode byte-exactness and its checksum manifest.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';

import 'package:gossip/src/membership/domain/messages/ack.dart';
import 'package:gossip/src/membership/domain/messages/ping.dart';
import 'package:gossip/src/membership/domain/messages/ping_req.dart';
import 'package:gossip/src/membership/infrastructure/membership_message_codec.dart';
import 'package:gossip/src/shared/domain/interfaces/protocol_message.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_types.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';
import 'package:gossip/src/sync/domain/messages/delta_request.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/messages/digest_response.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';

/// Set true ONCE to (re)write the fixture files, review the diff, then set
/// it back to false and re-run. The generator throws unconditionally, so a
/// regenerating build can never be green — mirrors gossip-kt's
/// `V1WireGoldenTest`.
const regenerate = false;

const _root = 'test/wire_vectors';

String _hashHex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

File _frameFile(String set, String name) => File('$_root/$set/$name.frame');

File _checksumsFile(String set) => File('$_root/$set/checksums.txt');

/// Writes `checksums.txt` for [set] from the frame files present in its
/// directory (alphabetical, so re-generation is deterministic regardless
/// of filesystem listing order).
void _writeChecksums(String set) {
  final dir = Directory('$_root/$set');
  final frameFiles =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.frame'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final lines = frameFiles.map((f) {
    final name = f.uri.pathSegments.last;
    return '${_hashHex(f.readAsBytesSync())}  $name';
  });
  _checksumsFile(set).writeAsStringSync('${lines.join('\n')}\n');
}

/// Reads `checksums.txt` for [set] as a manifest name -> hash map.
Map<String, String> _readChecksums(String set) {
  final manifest = <String, String>{};
  for (final line in _checksumsFile(set).readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final separator = line.indexOf('  ');
    manifest[line.substring(separator + 2)] = line.substring(0, separator);
  }
  return manifest;
}

void main() {
  // --- Shared scenario data (mirrors gossip-kt's V1WireGoldenTest) -------
  final nodeA = NodeId('node-a');
  final nodeB = NodeId('node-b');
  final ch1 = ChannelId('ch-1');
  final ch2 = ChannelId('ch-2');
  final st1 = StreamId('st-1');
  final st2 = StreamId('st-2');
  const unsignedPayload = [0, 1, 127, 128, 255];

  LogEntry entry(int sequence, {NodeId? author, List<int>? payload}) =>
      LogEntry(
        author: author ?? nodeA,
        sequence: sequence,
        timestamp: Hlc(1700000000000 + sequence, sequence),
        payload: Uint8List.fromList(payload ?? unsignedPayload),
      );

  List<ChannelDigest> digestsFixture() => [
    ChannelDigest(
      channelId: ch1,
      streams: [
        StreamDigest(
          streamId: st1,
          version: VersionVector({nodeA: 3, nodeB: 1}),
        ),
      ],
    ),
  ];

  // --- Codecs under version-dispatching facades ---------------------------
  final v1Sync = SyncMessageCodec(wireVersion: WireVersion.v1);
  final v2Sync = SyncMessageCodec(wireVersion: WireVersion.v2);
  final v1Membership = MembershipMessageCodec(wireVersion: WireVersion.v1);
  final v2Membership = MembershipMessageCodec(wireVersion: WireVersion.v2);

  Uint8List encodeFrame(ProtocolMessage message, WireVersion version) {
    final membership = version == WireVersion.v1 ? v1Membership : v2Membership;
    final sync = version == WireVersion.v1 ? v1Sync : v2Sync;
    if (message is Ping || message is Ack || message is PingReq) {
      return membership.encode(message);
    }
    return sync.encode(message);
  }

  // Decode is version-agnostic on both facades (only encode is gated by
  // wireVersion), so either instance decodes both dialects.
  ProtocolMessage? decodeFrame(Uint8List bytes) =>
      v1Membership.decode(bytes) ?? v1Sync.decode(bytes);

  // === v1-dart vectors ======================================================
  // §7.2: unprefixed frames, unsigned int-array payloads, additive `floor`.
  final v1DartVectors = <String, ProtocolMessage>{
    'ping': Ping(sender: nodeA, sequence: 7),
    'ack': Ack(sender: nodeB, sequence: 7),
    'pingreq': PingReq(sender: nodeA, sequence: 9, target: nodeB),
    'digestrequest': DigestRequest(sender: nodeA, digests: digestsFixture()),
    'digestresponse': DigestResponse(sender: nodeB, digests: digestsFixture()),
    // Three flat DeltaRequests, decomposing v1-kt's single batched
    // deltarequest.frame (ch-1/st-1, ch-1/st-2, ch-2/st-1) into the
    // per-(channel,stream) shape v1-dart and v2 both use.
    'deltarequest-1': DeltaRequest(
      sender: nodeA,
      channelId: ch1,
      streamId: st1,
      // `node-b: 0` is explicit in kt's batched source fixture, but
      // VersionVector treats a stored zero and an absent key as the same
      // value (see version_vector.dart's normalization) and drops it, so
      // the encoded `since` carries only `node-a`. Semantically identical;
      // disclosed here and in the README.
      since: VersionVector({nodeA: 2, nodeB: 0}),
    ),
    'deltarequest-2': DeltaRequest(
      sender: nodeA,
      channelId: ch1,
      streamId: st2,
      since: VersionVector({nodeA: 1}),
    ),
    'deltarequest-3': DeltaRequest(
      sender: nodeA,
      channelId: ch2,
      streamId: st1,
      since: VersionVector({nodeB: 3}),
    ),
    // Three flat DeltaResponses, decomposing v1-kt's batched
    // deltaresponse.frame the same way, with UNSIGNED payloads (v1-send
    // emission is always unsigned per §7.2 — the signed form is only ever
    // a decode-side accommodation for the deployed kt server).
    'deltaresponse-1': DeltaResponse(
      sender: nodeB,
      channelId: ch1,
      streamId: st1,
      entries: [entry(1), entry(2)],
    ),
    'deltaresponse-2': DeltaResponse(
      sender: nodeB,
      channelId: ch1,
      streamId: st2,
      entries: [entry(1, author: nodeB)],
    ),
    'deltaresponse-3': DeltaResponse(
      sender: nodeB,
      channelId: ch2,
      streamId: st1,
      entries: [entry(1)],
    ),
    // The "v1+floor" emission variant (§11 decision 3): v1-send may
    // additively carry `floor` so upgraded peers get the compaction-floor
    // benefit before the fleet reaches v2.
    'deltaresponse-floor': DeltaResponse(
      sender: nodeB,
      channelId: ch1,
      streamId: st1,
      entries: [entry(1)],
      floor: VersionVector({nodeA: 2}),
    ),
  };

  // === v2 vectors ===========================================================
  // §7.3: `[0xF2][type][JSON]`. Types 0-5 reuse v1-dart's values; type 6
  // (DeltaResponse) exercises hasMore, floor, and base64 payload together.
  final v2Vectors = <String, ProtocolMessage>{
    'ping': Ping(sender: nodeA, sequence: 7),
    'ack': Ack(sender: nodeB, sequence: 7),
    'pingreq': PingReq(sender: nodeA, sequence: 9, target: nodeB),
    'digestrequest': DigestRequest(sender: nodeA, digests: digestsFixture()),
    'digestresponse': DigestResponse(sender: nodeB, digests: digestsFixture()),
    'deltarequest': DeltaRequest(
      sender: nodeA,
      channelId: ch1,
      streamId: st1,
      since: VersionVector({nodeA: 2, nodeB: 0}), // see v1-dart's note above
    ),
    'deltaresponse': DeltaResponse(
      sender: nodeB,
      channelId: ch1,
      streamId: st1,
      entries: [entry(1), entry(2)],
      hasMore: true,
      floor: VersionVector({nodeA: 2}),
    ),
  };

  // === v1-kt new frames (hand-built; Dart never decodes this dialect) =====
  // §7.4's batched shape has no Dart domain equivalent, so these are
  // authored directly as JSON, matching the brief's literal shapes.
  Map<String, dynamic> ktEntryJson(
    int sequence, {
    String author = 'node-a',
    List<int> payload = unsignedPayload,
  }) => {
    'author': author,
    'sequence': sequence,
    'timestamp': {'physicalMs': 1700000000000 + sequence, 'logical': sequence},
    'payload': payload,
  };

  final v1KtNewFrames = <String, Uint8List>{
    // Wraps v1-dart's deltarequest-1 in the batched envelope, single
    // channel/stream — the minimal case beyond the fully-nested existing
    // golden.
    'deltarequest-single': Uint8List.fromList([
      WireTypes.deltaRequest,
      ...utf8.encode(
        jsonEncode({
          'sender': 'node-a',
          'channelDeltas': {
            'ch-1': {
              'st-1': {'node-a': 2, 'node-b': 0},
            },
          },
        }),
      ),
    ]),
    // Wraps v1-dart's deltaresponse-1, unsigned payload (the upgraded
    // kt-emission form — §7.4's normalization rule).
    'deltaresponse-single': Uint8List.fromList([
      WireTypes.deltaResponse,
      ...utf8.encode(
        jsonEncode({
          'sender': 'node-b',
          'entries': {
            'ch-1': {
              'st-1': [ktEntryJson(1), ktEntryJson(2)],
            },
          },
        }),
      ),
    ]),
    // The v1-kt "v1+floor" variant (§11 decision 3, §7.4): floor structured
    // per (channelId, streamId) alongside the nested entries map.
    'deltaresponse-floor': Uint8List.fromList([
      WireTypes.deltaResponse,
      ...utf8.encode(
        jsonEncode({
          'sender': 'node-b',
          'entries': {
            'ch-1': {
              'st-1': [ktEntryJson(1)],
            },
          },
          'floor': {
            'ch-1': {
              'st-1': {'node-a': 2},
            },
          },
        }),
      ),
    ]),
  };

  // === edge vectors (hand-built bytes; not routed through the codecs) =====
  Map<String, dynamic> rawEntry({
    required String author,
    required int sequence,
    required List<int> payload,
  }) => {
    'author': author,
    'sequence': sequence,
    'timestamp': {'physicalMs': 1700000000000 + sequence, 'logical': sequence},
    'payload': payload,
  };

  Uint8List v1FrameBytes(int type, Map<String, dynamic> json) =>
      Uint8List.fromList([type, ...utf8.encode(jsonEncode(json))]);

  Uint8List v2FrameBytes(int type, Map<String, dynamic> json) =>
      Uint8List.fromList([
        WireTypes.markerV2,
        type,
        ...utf8.encode(jsonEncode(json)),
      ]);

  final edgeFrames = <String, Uint8List>{
    'empty': Uint8List(0),
    'reserved-07': Uint8List.fromList([0x07, 0x01]),
    'reserved-80': Uint8List.fromList([0x80, 0x01]),
    'marker-f0': Uint8List.fromList([0xF0, 0x01]),
    'marker-f1': Uint8List.fromList([0xF1, 0x01]),
    'marker-f3': Uint8List.fromList([0xF3, 0x01]),
    'escape-ff': Uint8List.fromList([0xFF, 0x01]),
    'marker-only': Uint8List.fromList([WireTypes.markerV2]),
    'malformed-json': Uint8List.fromList([
      WireTypes.digestRequest,
      ...utf8.encode('not json'),
    ]),
    // §7.3 decoder grace: a legacy int-list payload inside a v2 frame must
    // still decode.
    'v2-intlist-payload': v2FrameBytes(WireTypes.deltaResponse, {
      'sender': 'node-a',
      'channelId': 'ch-1',
      'streamId': 'st-1',
      'entries': [
        rawEntry(author: 'node-a', sequence: 1, payload: const [1, 2, 3]),
      ],
      'hasMore': false,
    }),
    // §7.2's widened decode range: negative elements in -128..-1 are what
    // the deployed kt server actually emits and MUST decode, normalizing
    // to their unsigned byte value.
    'v1-payload-signed': v1FrameBytes(WireTypes.deltaResponse, {
      'sender': 'node-b',
      'channelId': 'ch-1',
      'streamId': 'st-1',
      'entries': [
        rawEntry(author: 'node-a', sequence: 1, payload: const [0, -1, -128]),
      ],
    }),
    // Outside -128..255 under any interpretation: corruption, rejected.
    'v1-payload-out-of-range': v1FrameBytes(WireTypes.deltaResponse, {
      'sender': 'node-b',
      'channelId': 'ch-1',
      'streamId': 'st-1',
      'entries': [
        rawEntry(author: 'node-a', sequence: 1, payload: const [300]),
      ],
    }),
    // No hasMore/floor keys at all: decode must default them, not throw.
    'v1-deltaresponse-defaults': v1FrameBytes(WireTypes.deltaResponse, {
      'sender': 'node-b',
      'channelId': 'ch-1',
      'streamId': 'st-1',
      'entries': [
        rawEntry(author: 'node-a', sequence: 1, payload: unsignedPayload),
      ],
    }),
  };

  // === Generator ============================================================
  test('fixtures are up to date', () {
    if (!regenerate) return;

    Directory('$_root/v1-dart').createSync(recursive: true);
    v1DartVectors.forEach((name, message) {
      _frameFile(
        'v1-dart',
        name,
      ).writeAsBytesSync(encodeFrame(message, WireVersion.v1));
    });
    _writeChecksums('v1-dart');

    Directory('$_root/v2').createSync(recursive: true);
    v2Vectors.forEach((name, message) {
      _frameFile(
        'v2',
        name,
      ).writeAsBytesSync(encodeFrame(message, WireVersion.v2));
    });
    _writeChecksums('v2');

    // The 10 pre-existing v1-kt frames are byte-copies of gossip-kt's own
    // committed goldens and are NEVER rewritten here — only the 3 new
    // Dart-authored frames are written, then the manifest covers all 13.
    Directory('$_root/v1-kt').createSync(recursive: true);
    v1KtNewFrames.forEach((name, bytes) {
      _frameFile('v1-kt', name).writeAsBytesSync(bytes);
    });
    _writeChecksums('v1-kt');

    Directory('$_root/edge').createSync(recursive: true);
    edgeFrames.forEach((name, bytes) {
      _frameFile('edge', name).writeAsBytesSync(bytes);
    });
    _writeChecksums('edge');

    throw AssertionError(
      'Wire fixtures regenerated. Review the diff, set regenerate = false, '
      're-run.',
    );
  });

  // === Verification: v1-dart ================================================
  group('v1-dart', () {
    v1DartVectors.forEach((name, message) {
      test('$name matches its golden bytes', () {
        final golden = _frameFile('v1-dart', name).readAsBytesSync();

        expect(
          encodeFrame(message, WireVersion.v1),
          equals(golden),
          reason: 'encode($name)',
        );

        final decoded = decodeFrame(golden);
        expect(
          decoded?.runtimeType,
          equals(message.runtimeType),
          reason: 'decode($name) produced ${decoded?.runtimeType}',
        );
        expect(
          encodeFrame(decoded!, WireVersion.v1),
          equals(golden),
          reason: 'decode->encode($name)',
        );
      });
    });

    test('every fixture matches its recorded checksum', () {
      final recorded = _readChecksums('v1-dart');
      expect(
        recorded.keys.toSet(),
        equals(v1DartVectors.keys.map((n) => '$n.frame').toSet()),
      );
      recorded.forEach((file, expectedHash) {
        expect(
          _hashHex(File('$_root/v1-dart/$file').readAsBytesSync()),
          equals(expectedHash),
          reason: file,
        );
      });
    });
  });

  // === Verification: v2 =====================================================
  group('v2', () {
    v2Vectors.forEach((name, message) {
      test('$name matches its golden bytes', () {
        final golden = _frameFile('v2', name).readAsBytesSync();

        expect(
          encodeFrame(message, WireVersion.v2),
          equals(golden),
          reason: 'encode($name)',
        );

        final decoded = decodeFrame(golden);
        expect(
          decoded?.runtimeType,
          equals(message.runtimeType),
          reason: 'decode($name) produced ${decoded?.runtimeType}',
        );
        expect(
          encodeFrame(decoded!, WireVersion.v2),
          equals(golden),
          reason: 'decode->encode($name)',
        );
      });
    });

    test('every fixture matches its recorded checksum', () {
      final recorded = _readChecksums('v2');
      expect(
        recorded.keys.toSet(),
        equals(v2Vectors.keys.map((n) => '$n.frame').toSet()),
      );
      recorded.forEach((file, expectedHash) {
        expect(
          _hashHex(File('$_root/v2/$file').readAsBytesSync()),
          equals(expectedHash),
          reason: file,
        );
      });
    });
  });

  // === Verification: v1-kt (checksums only — Dart never decodes it) =======
  group('v1-kt', () {
    test('every fixture matches its recorded checksum', () {
      final recorded = _readChecksums('v1-kt');
      final expectedNames = {
        'ack',
        'deltarequest',
        'deltaresponse',
        'deltaresponseemptypayload',
        'deltaresponseemptystream',
        'digestrequest',
        'digestrequestnonascii',
        'digestresponse',
        'ping',
        'pingreq',
        ...v1KtNewFrames.keys,
      };
      expect(
        recorded.keys.toSet(),
        equals(expectedNames.map((n) => '$n.frame').toSet()),
      );
      recorded.forEach((file, expectedHash) {
        expect(
          _hashHex(File('$_root/v1-kt/$file').readAsBytesSync()),
          equals(expectedHash),
          reason: file,
        );
      });
    });
  });

  // === Verification: edge (per-frame behavior; frames shared, outcomes
  // library-local) ===========================================================
  group('edge', () {
    for (final name in [
      'empty',
      'reserved-07',
      'reserved-80',
      'marker-f0',
      'marker-f1',
      'marker-f3',
      'escape-ff',
      'marker-only',
    ]) {
      test('$name is rejected by both codecs', () {
        final bytes = _frameFile('edge', name).readAsBytesSync();
        expect(() => v1Sync.decode(bytes), throwsArgumentError);
        expect(() => v1Membership.decode(bytes), throwsArgumentError);
      });
    }

    test("malformed-json is rejected by the sync codec (type 3 is sync's) "
        'and ignored as foreign traffic by the membership codec', () {
      final bytes = _frameFile('edge', 'malformed-json').readAsBytesSync();
      expect(() => v1Sync.decode(bytes), throwsA(anything));
      expect(v1Membership.decode(bytes), isNull);
    });

    test(
      'v2-intlist-payload decodes under the legacy int-list decoder grace',
      () {
        final bytes = _frameFile(
          'edge',
          'v2-intlist-payload',
        ).readAsBytesSync();
        final decoded = v1Sync.decode(bytes) as DeltaResponse;
        expect(
          decoded.entries.single.payload,
          equals(Uint8List.fromList([1, 2, 3])),
        );
      },
    );

    test('v1-payload-signed decodes, normalizing negative bytes to unsigned '
        '(the deployed kt server emission)', () {
      final bytes = _frameFile('edge', 'v1-payload-signed').readAsBytesSync();
      final decoded = v1Sync.decode(bytes) as DeltaResponse;
      expect(
        decoded.entries.single.payload,
        equals(Uint8List.fromList([0, 255, 128])),
      );
    });

    test('v1-payload-out-of-range is rejected', () {
      final bytes = _frameFile(
        'edge',
        'v1-payload-out-of-range',
      ).readAsBytesSync();
      expect(() => v1Sync.decode(bytes), throwsArgumentError);
    });

    test(
      'v1-deltaresponse-defaults decodes hasMore=false and an empty floor',
      () {
        final bytes = _frameFile(
          'edge',
          'v1-deltaresponse-defaults',
        ).readAsBytesSync();
        final decoded = v1Sync.decode(bytes) as DeltaResponse;
        expect(decoded.hasMore, isFalse);
        expect(decoded.floor, equals(VersionVector.empty));
      },
    );

    test('every fixture matches its recorded checksum', () {
      final recorded = _readChecksums('edge');
      expect(
        recorded.keys.toSet(),
        equals(edgeFrames.keys.map((n) => '$n.frame').toSet()),
      );
      recorded.forEach((file, expectedHash) {
        expect(
          _hashHex(File('$_root/edge/$file').readAsBytesSync()),
          equals(expectedHash),
          reason: file,
        );
      });
    });
  });
}
