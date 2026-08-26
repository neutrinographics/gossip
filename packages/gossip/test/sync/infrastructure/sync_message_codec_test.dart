import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/membership/domain/messages/ping.dart';
import 'package:gossip/src/membership/infrastructure/membership_message_codec.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/messages/digest_response.dart';
import 'package:gossip/src/sync/domain/messages/delta_request.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';

void main() {
  group('SyncMessageCodec', () {
    final codec = SyncMessageCodec();

    DeltaResponse responseWith(List<LogEntry> entries) => DeltaResponse(
      sender: NodeId('sender'),
      channelId: ChannelId('ch1'),
      streamId: StreamId('s1'),
      entries: entries,
    );

    Map<String, dynamic> jsonOf(Uint8List encoded) =>
        jsonDecode(utf8.decode(encoded.sublist(1))) as Map<String, dynamic>;

    test('round-trips DigestRequest', () {
      final sender = NodeId('peer1');
      final channelId = ChannelId('channel1');
      final streamId = StreamId('stream1');
      final version = VersionVector({sender: 5});
      final streamDigest = StreamDigest(streamId: streamId, version: version);
      final channelDigest = ChannelDigest(
        channelId: channelId,
        streams: [streamDigest],
      );
      final request = DigestRequest(sender: sender, digests: [channelDigest]);

      final decoded = codec.decode(codec.encode(request)) as DigestRequest;
      expect(decoded.sender, equals(sender));
      expect(decoded.digests, hasLength(1));
      expect(decoded.digests[0].channelId, equals(channelId));
      expect(decoded.digests[0].streams, hasLength(1));
      expect(decoded.digests[0].streams[0].streamId, equals(streamId));
      expect(decoded.digests[0].streams[0].version[sender], equals(5));
    });

    test('round-trips DigestResponse', () {
      final sender = NodeId('peer2');
      final channelId = ChannelId('channel1');
      final streamId = StreamId('stream1');
      final author = NodeId('author1');
      final version = VersionVector({author: 3});
      final streamDigest = StreamDigest(streamId: streamId, version: version);
      final channelDigest = ChannelDigest(
        channelId: channelId,
        streams: [streamDigest],
      );
      final response = DigestResponse(sender: sender, digests: [channelDigest]);

      final decoded = codec.decode(codec.encode(response)) as DigestResponse;
      expect(decoded.sender, equals(sender));
      expect(decoded.digests, hasLength(1));
      expect(decoded.digests[0].channelId, equals(channelId));
      expect(decoded.digests[0].streams, hasLength(1));
      expect(decoded.digests[0].streams[0].streamId, equals(streamId));
      expect(decoded.digests[0].streams[0].version[author], equals(3));
    });

    test('round-trips DeltaRequest', () {
      final sender = NodeId('peer1');
      final channelId = ChannelId('channel1');
      final streamId = StreamId('stream1');
      final author = NodeId('author1');
      final since = VersionVector({author: 2});
      final request = DeltaRequest(
        sender: sender,
        channelId: channelId,
        streamId: streamId,
        since: since,
      );

      final decoded = codec.decode(codec.encode(request)) as DeltaRequest;
      expect(decoded.sender, equals(sender));
      expect(decoded.channelId, equals(channelId));
      expect(decoded.streamId, equals(streamId));
      expect(decoded.since[author], equals(2));
    });

    test('round-trips DeltaResponse (incl. floor + hasMore)', () {
      final sender = NodeId('peer2');
      final channelId = ChannelId('channel1');
      final streamId = StreamId('stream1');
      final author = NodeId('author1');

      final entry1 = LogEntry(
        author: author,
        sequence: 1,
        timestamp: Hlc(1000, 0),
        payload: Uint8List.fromList([1, 2, 3]),
      );
      final response = DeltaResponse(
        sender: sender,
        channelId: channelId,
        streamId: streamId,
        entries: [entry1],
        hasMore: true,
        floor: VersionVector({author: 10}),
      );

      final decoded = codec.decode(codec.encode(response)) as DeltaResponse;
      expect(decoded.entries.single.payload, equals(entry1.payload));
      expect(decoded.hasMore, isTrue);
      expect(decoded.floor[author], equals(10));
    });

    test('round-trips a DeltaResponse with multiple entries '
        '(per-entry field fidelity)', () {
      final sender = NodeId('peer2');
      final channelId = ChannelId('channel1');
      final streamId = StreamId('stream1');
      final author = NodeId('author1');

      final entry1 = LogEntry(
        author: author,
        sequence: 1,
        timestamp: Hlc(1000, 0),
        payload: Uint8List.fromList([1, 2, 3]),
      );
      final entry2 = LogEntry(
        author: author,
        sequence: 2,
        timestamp: Hlc(2000, 1),
        payload: Uint8List.fromList([4, 5, 6]),
      );

      final response = DeltaResponse(
        sender: sender,
        channelId: channelId,
        streamId: streamId,
        entries: [entry1, entry2],
      );

      final decoded = codec.decode(codec.encode(response)) as DeltaResponse;
      expect(decoded.sender, equals(sender));
      expect(decoded.channelId, equals(channelId));
      expect(decoded.streamId, equals(streamId));
      expect(decoded.entries, hasLength(2));

      expect(decoded.entries[0].author, equals(author));
      expect(decoded.entries[0].sequence, equals(1));
      expect(decoded.entries[0].timestamp, equals(Hlc(1000, 0)));
      expect(decoded.entries[0].payload, equals(Uint8List.fromList([1, 2, 3])));

      expect(decoded.entries[1].author, equals(author));
      expect(decoded.entries[1].sequence, equals(2));
      expect(decoded.entries[1].timestamp, equals(Hlc(2000, 1)));
      expect(decoded.entries[1].payload, equals(Uint8List.fromList([4, 5, 6])));
      expect(decoded.floor.entries, isEmpty, reason: 'no floor was set');
    });

    test('DeltaResponse round-trips with no floor set (default)', () {
      final response = DeltaResponse(
        sender: NodeId('peer2'),
        channelId: ChannelId('channel1'),
        streamId: StreamId('stream1'),
        entries: const [],
      );

      final decoded = codec.decode(codec.encode(response)) as DeltaResponse;
      expect(decoded.floor.entries, isEmpty, reason: 'no floor was set');
    });

    test('DeltaResponse without a floor field decodes to an empty floor '
        '(legacy senders, COR3-1)', () {
      // A legacy sender's message: same wire format minus the floor key.
      final legacyJson = utf8.encode(
        jsonEncode({
          'sender': 'peer2',
          'channelId': 'channel1',
          'streamId': 'stream1',
          'entries': <Object>[],
          'hasMore': false,
        }),
      );
      final bytes = Uint8List(legacyJson.length + 1);
      bytes[0] = 6; // DeltaResponse type byte
      bytes.setRange(1, bytes.length, legacyJson);

      final decoded = codec.decode(bytes) as DeltaResponse;
      expect(decoded.floor.entries, isEmpty);
    });

    test('decode returns null for a frame from the membership family', () {
      final ping = Ping(sender: NodeId('peer1'), sequence: 1);
      final bytes = MembershipMessageCodec().encode(ping);

      expect(codec.decode(bytes), isNull);
    });

    test('decode throws ArgumentError for empty bytes (own malformed-frame '
        'behavior)', () {
      expect(
        () => codec.decode(Uint8List(0)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'Cannot decode empty bytes',
          ),
        ),
      );
    });

    test('decode throws on malformed JSON for its own family type byte', () {
      // Type byte 3 (DigestRequest) with a body that isn't valid JSON.
      final bytes = Uint8List.fromList([3, ...utf8.encode('not json')]);

      expect(() => codec.decode(bytes), throwsA(isA<Object>()));
    });

    test('decode throws ArgumentError for a type byte outside every known '
        'family (genuinely corrupt, not just "not mine")', () {
      // 255 belongs to neither membership (0-2) nor sync (3-6) — unlike
      // the membership-family test above, this must NOT be treated as
      // routine foreign traffic.
      final bytes = Uint8List.fromList([255, 0, 1, 2, 3]);

      expect(
        () => codec.decode(bytes),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'Unknown message type: 255',
          ),
        ),
      );
    });

    group('payload encoding', () {
      test('encodes entry payloads as base64 strings, not int lists', () {
        final payload = Uint8List.fromList(List.generate(256, (i) => i));
        final encoded = codec.encode(
          responseWith([
            LogEntry(
              author: NodeId('a'),
              sequence: 1,
              timestamp: Hlc(1000, 0),
              payload: payload,
            ),
          ]),
        );

        final entryJson =
            (jsonOf(encoded)['entries'] as List).first as Map<String, dynamic>;
        expect(
          entryJson['payload'],
          isA<String>(),
          reason: 'JSON int lists inflate payloads ~3.6x; base64 is ~1.33x',
        );

        // Round trip must preserve the exact bytes.
        final decoded = codec.decode(encoded) as DeltaResponse;
        expect(decoded.entries.single.payload, equals(payload));
      });

      test('encoded size stays near base64 overhead for binary payloads', () {
        final payload = Uint8List.fromList(
          List.generate(8 * 1024, (i) => (i * 37 + 11) % 256),
        );
        final encoded = codec.encode(
          responseWith([
            LogEntry(
              author: NodeId('a'),
              sequence: 1,
              timestamp: Hlc(1000, 0),
              payload: payload,
            ),
          ]),
        );

        // 8KB base64 ≈ 10.9KB; allow generous envelope slack. The legacy
        // int-list encoding averaged ~3.6 chars/byte (~29KB) and must be gone.
        expect(encoded.length, lessThan(12 * 1024));
      });

      test('round-trips the DeltaResponse hasMore flag', () {
        final encoded = codec.encode(
          DeltaResponse(
            sender: NodeId('sender'),
            channelId: ChannelId('ch1'),
            streamId: StreamId('s1'),
            entries: const [],
            hasMore: true,
          ),
        );
        final decoded = codec.decode(encoded) as DeltaResponse;
        expect(decoded.hasMore, isTrue);
      });

      test('a legacy DeltaResponse without hasMore decodes to false', () {
        final legacyJson = {
          'sender': 'sender',
          'channelId': 'ch1',
          'streamId': 's1',
          'entries': <dynamic>[],
        };
        final bytes = Uint8List.fromList([
          6, // DeltaResponse type byte
          ...utf8.encode(jsonEncode(legacyJson)),
        ]);
        final decoded = codec.decode(bytes) as DeltaResponse;
        expect(decoded.hasMore, isFalse);
      });

      test('still decodes legacy int-list payloads', () {
        final legacyJson = {
          'sender': 'sender',
          'channelId': 'ch1',
          'streamId': 's1',
          'entries': [
            {
              'author': 'a',
              'sequence': 1,
              'timestamp': {'physicalMs': 1000, 'logical': 0},
              'payload': [1, 2, 3, 255],
            },
          ],
        };
        final bytes = Uint8List.fromList([
          6, // DeltaResponse type byte
          ...utf8.encode(jsonEncode(legacyJson)),
        ]);

        final decoded = codec.decode(bytes) as DeltaResponse;
        expect(
          decoded.entries.single.payload,
          equals(Uint8List.fromList([1, 2, 3, 255])),
        );
      });

      test('maxEntryPayloadForBudget-sized payload fits the budget', () {
        const budget = 30 * 1024;
        final maxPayload = SyncMessageCodec.maxEntryPayloadForBudget(budget);

        // Sanity: base64 + envelope means roughly 3/4 of the budget.
        expect(maxPayload, greaterThan(20 * 1024));
        expect(maxPayload, lessThan(budget));

        // A single-entry DeltaResponse at exactly the derived max must
        // encode within the budget (worst-case author/id lengths).
        final encoded = codec.encode(
          responseWith([
            LogEntry(
              author: NodeId('a' * 64), // longer than a UUID
              sequence: 1 << 40,
              timestamp: Hlc(281474976710655, 65535), // max HLC fields
              payload: Uint8List.fromList(
                List.generate(maxPayload, (i) => i % 256),
              ),
            ),
          ]),
        );
        expect(encoded.length, lessThanOrEqualTo(budget));
      });

      test(
        'rejects legacy payload bytes outside 0-255 instead of truncating',
        () {
          final malformedJson = {
            'sender': 'sender',
            'channelId': 'ch1',
            'streamId': 's1',
            'entries': [
              {
                'author': 'a',
                'sequence': 1,
                'timestamp': {'physicalMs': 1000, 'logical': 0},
                'payload': [300, -1],
              },
            ],
          };
          final bytes = Uint8List.fromList([
            6,
            ...utf8.encode(jsonEncode(malformedJson)),
          ]);

          expect(
            () => codec.decode(bytes),
            throwsA(isA<Object>()),
            reason: 'out-of-range bytes are corruption, not data to mod-256',
          );
        },
      );
    });

    group('encode-side wire pinning (CC5-30)', () {
      // Every literal type byte and key set below is copied by hand from
      // the codec, not read from WireTypes or the codec's own encoder. A
      // round-trip test (decode(encode(x))) stays green even if the
      // encoder and decoder drift together — e.g. both sides rename a
      // JSON key, or both sides get the same (wrong) type-byte edit. An
      // independently-sourced literal is the only thing that can catch
      // that: it fails when THIS codec's output differs from what a
      // previously-deployed peer's codec would still expect.
      test('DigestRequest encodes with wire type byte 3 and the '
          'sender/digests key set', () {
        final request = DigestRequest(
          sender: NodeId('peer1'),
          digests: const [],
        );
        final encoded = codec.encode(request);

        expect(encoded[0], equals(3));
        expect(jsonOf(encoded).keys.toSet(), equals({'sender', 'digests'}));
      });

      test('DigestResponse encodes with wire type byte 4 and the '
          'sender/digests key set', () {
        final response = DigestResponse(
          sender: NodeId('peer1'),
          digests: const [],
        );
        final encoded = codec.encode(response);

        expect(encoded[0], equals(4));
        expect(jsonOf(encoded).keys.toSet(), equals({'sender', 'digests'}));
      });

      test('DeltaRequest encodes with wire type byte 5 and the '
          'sender/channelId/streamId/since key set', () {
        final request = DeltaRequest(
          sender: NodeId('peer1'),
          channelId: ChannelId('channel1'),
          streamId: StreamId('stream1'),
          since: VersionVector.empty,
        );
        final encoded = codec.encode(request);

        expect(encoded[0], equals(5));
        expect(
          jsonOf(encoded).keys.toSet(),
          equals({'sender', 'channelId', 'streamId', 'since'}),
        );
      });

      test('DeltaResponse encodes with wire type byte 6 and the '
          'sender/channelId/streamId/entries/hasMore key set (no floor)', () {
        final encoded = codec.encode(responseWith(const []));

        expect(encoded[0], equals(6));
        expect(
          jsonOf(encoded).keys.toSet(),
          equals({'sender', 'channelId', 'streamId', 'entries', 'hasMore'}),
        );
      });

      test('DigestRequest nested digest encodes channelId/streams/streamId/'
          'version with version-vector entries as author→seq', () {
        final request = DigestRequest(
          sender: NodeId('peer1'),
          digests: [
            ChannelDigest(
              channelId: ChannelId('ch1'),
              streams: [
                StreamDigest(
                  streamId: StreamId('s1'),
                  version: VersionVector({NodeId('peer1'): 5}),
                ),
              ],
            ),
          ],
        );

        final json = jsonOf(codec.encode(request));
        final digest = (json['digests'] as List).single as Map<String, dynamic>;
        expect(digest.keys.toSet(), equals({'channelId', 'streams'}));
        final stream =
            (digest['streams'] as List).single as Map<String, dynamic>;
        expect(stream.keys.toSet(), equals({'streamId', 'version'}));
        expect(stream['version'], equals({'peer1': 5}));
      });

      test('DigestResponse nested digest uses the same wire shape as '
          'DigestRequest', () {
        final response = DigestResponse(
          sender: NodeId('peer1'),
          digests: [
            ChannelDigest(
              channelId: ChannelId('ch1'),
              streams: [
                StreamDigest(
                  streamId: StreamId('s1'),
                  version: VersionVector({NodeId('peer1'): 5}),
                ),
              ],
            ),
          ],
        );

        final json = jsonOf(codec.encode(response));
        final digest = (json['digests'] as List).single as Map<String, dynamic>;
        expect(digest.keys.toSet(), equals({'channelId', 'streams'}));
        final stream =
            (digest['streams'] as List).single as Map<String, dynamic>;
        expect(stream.keys.toSet(), equals({'streamId', 'version'}));
        expect(stream['version'], equals({'peer1': 5}));
      });

      test(
        'DeltaRequest since encodes as a version-vector map of author→seq',
        () {
          final request = DeltaRequest(
            sender: NodeId('peer1'),
            channelId: ChannelId('ch1'),
            streamId: StreamId('s1'),
            since: VersionVector({NodeId('peer1'): 3, NodeId('peer2'): 7}),
          );

          final json = jsonOf(codec.encode(request));
          expect(json['since'], equals({'peer1': 3, 'peer2': 7}));
        },
      );

      test('DeltaResponse entry encodes author/sequence/timestamp/payload with '
          'an Hlc timestamp object and base64 payload; a non-empty floor '
          'encodes as a version-vector map', () {
        final response = DeltaResponse(
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
          floor: VersionVector({NodeId('peer1'): 3}),
        );

        final json = jsonOf(codec.encode(response));
        final entry = (json['entries'] as List).single as Map<String, dynamic>;
        expect(
          entry.keys.toSet(),
          equals({'author', 'sequence', 'timestamp', 'payload'}),
        );
        expect(entry['author'], equals('peer1'));
        expect(entry['sequence'], equals(1));
        expect(entry['timestamp'], equals({'physicalMs': 1000, 'logical': 2}));
        expect(entry['payload'], equals('AQID')); // base64 of [1, 2, 3]
        expect(json['floor'], equals({'peer1': 3}));
      });
    });

    group('byte-budget helpers', () {
      // gossip_engine.dart uses these to budget DeltaResponse/DigestRequest
      // messages against the 32KB transport limit without repeatedly
      // encoding whole messages (see gossip_engine.dart:798,1517). The
      // expectations here are derived from an *actual* encoded message,
      // not by re-running the helper's own formula, so a drift between
      // the estimate and the real wire size would fail this test.
      test('encodedEntrySize equals the entry\'s actual size inside an '
          'encoded DeltaResponse', () {
        final entry = LogEntry(
          author: NodeId('author-with-a-realistic-length-id'),
          sequence: 99999,
          timestamp: Hlc(281474976710655, 65535), // max HLC fields
          payload: Uint8List.fromList(List.generate(37, (i) => i)),
        );
        final encoded = codec.encode(responseWith([entry]));

        final entryJson = (jsonOf(encoded)['entries'] as List).single;
        final actualEntrySize = utf8.encode(jsonEncode(entryJson)).length;

        expect(codec.encodedEntrySize(entry), equals(actualEntrySize));
      });

      test('encodedStreamDigestSize equals the stream digest\'s actual '
          'size inside an encoded DigestResponse', () {
        final digest = StreamDigest(
          streamId: StreamId('stream-with-a-realistic-length-id'),
          version: VersionVector({NodeId('author1'): 42, NodeId('author2'): 7}),
        );
        final response = DigestResponse(
          sender: NodeId('sender'),
          digests: [
            ChannelDigest(channelId: ChannelId('ch1'), streams: [digest]),
          ],
        );
        final encoded = codec.encode(response);

        final channelJson =
            (jsonOf(encoded)['digests'] as List).single as Map<String, dynamic>;
        final streamJson = (channelJson['streams'] as List).single;
        final actualDigestSize = utf8.encode(jsonEncode(streamJson)).length;

        expect(codec.encodedStreamDigestSize(digest), equals(actualDigestSize));
      });
    });
  });
}
