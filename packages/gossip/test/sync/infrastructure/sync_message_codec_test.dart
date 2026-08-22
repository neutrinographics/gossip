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
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';
import 'package:gossip/src/protocol/messages/delta_request.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:gossip/src/protocol/values/stream_digest.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';

void main() {
  group('SyncMessageCodec', () {
    final codec = SyncMessageCodec();
    final legacyCodec = ProtocolCodec();

    test('wire-freeze: round-trips DigestRequest byte-identically with '
        'ProtocolCodec', () {
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

      final bytesFromNew = codec.encode(request);
      final bytesFromLegacy = legacyCodec.encode(request);
      expect(bytesFromNew, equals(bytesFromLegacy));

      final decodedByLegacy = legacyCodec.decode(bytesFromNew) as DigestRequest;
      expect(decodedByLegacy.sender, equals(sender));
      expect(decodedByLegacy.digests[0].streams[0].version[sender], equals(5));

      final decodedByNew = codec.decode(bytesFromLegacy) as DigestRequest;
      expect(decodedByNew.sender, equals(sender));
      expect(decodedByNew.digests[0].streams[0].version[sender], equals(5));
    });

    test('wire-freeze: round-trips DigestResponse byte-identically with '
        'ProtocolCodec', () {
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

      final bytesFromNew = codec.encode(response);
      final bytesFromLegacy = legacyCodec.encode(response);
      expect(bytesFromNew, equals(bytesFromLegacy));

      final decodedByLegacy =
          legacyCodec.decode(bytesFromNew) as DigestResponse;
      expect(decodedByLegacy.digests[0].streams[0].version[author], 3);

      final decodedByNew = codec.decode(bytesFromLegacy) as DigestResponse;
      expect(decodedByNew.digests[0].streams[0].version[author], 3);
    });

    test('wire-freeze: round-trips DeltaRequest byte-identically with '
        'ProtocolCodec', () {
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

      final bytesFromNew = codec.encode(request);
      final bytesFromLegacy = legacyCodec.encode(request);
      expect(bytesFromNew, equals(bytesFromLegacy));

      final decodedByLegacy = legacyCodec.decode(bytesFromNew) as DeltaRequest;
      expect(decodedByLegacy.channelId, equals(channelId));
      expect(decodedByLegacy.since[author], equals(2));

      final decodedByNew = codec.decode(bytesFromLegacy) as DeltaRequest;
      expect(decodedByNew.channelId, equals(channelId));
      expect(decodedByNew.since[author], equals(2));
    });

    test('wire-freeze: round-trips DeltaResponse (incl. floor + hasMore) '
        'byte-identically with ProtocolCodec', () {
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

      final bytesFromNew = codec.encode(response);
      final bytesFromLegacy = legacyCodec.encode(response);
      expect(bytesFromNew, equals(bytesFromLegacy));

      final decodedByLegacy = legacyCodec.decode(bytesFromNew) as DeltaResponse;
      expect(decodedByLegacy.entries.single.payload, equals(entry1.payload));
      expect(decodedByLegacy.hasMore, isTrue);
      expect(decodedByLegacy.floor[author], equals(10));

      final decodedByNew = codec.decode(bytesFromLegacy) as DeltaResponse;
      expect(decodedByNew.entries.single.payload, equals(entry1.payload));
      expect(decodedByNew.hasMore, isTrue);
      expect(decodedByNew.floor[author], equals(10));
    });

    test('decode returns null for a frame from the membership family', () {
      final ping = Ping(sender: NodeId('peer1'), sequence: 1);
      final bytes = legacyCodec.encode(ping);

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

    test('maxEntryPayloadForBudget-sized payload fits the budget', () {
      const budget = 30 * 1024;
      final maxPayload = SyncMessageCodec.maxEntryPayloadForBudget(budget);

      expect(maxPayload, greaterThan(20 * 1024));
      expect(maxPayload, lessThan(budget));

      final encoded = codec.encode(
        DeltaResponse(
          sender: NodeId('sender'),
          channelId: ChannelId('ch1'),
          streamId: StreamId('s1'),
          entries: [
            LogEntry(
              author: NodeId('a' * 64),
              sequence: 1 << 40,
              timestamp: Hlc(281474976710655, 65535),
              payload: Uint8List.fromList(
                List.generate(maxPayload, (i) => i % 256),
              ),
            ),
          ],
        ),
      );
      expect(encoded.length, lessThanOrEqualTo(budget));

      // Must match ProtocolCodec's static helper (delegation, not drift).
      expect(
        maxPayload,
        equals(ProtocolCodec.maxEntryPayloadForBudget(budget)),
      );
    });

    test(
      'encodedEntrySize and encodedStreamDigestSize match ProtocolCodec',
      () {
        final entry = LogEntry(
          author: NodeId('a'),
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([1, 2, 3]),
        );
        expect(
          codec.encodedEntrySize(entry),
          equals(legacyCodec.encodedEntrySize(entry)),
        );

        final digest = StreamDigest(
          streamId: StreamId('s1'),
          version: VersionVector({NodeId('a'): 1}),
        );
        expect(
          codec.encodedStreamDigestSize(digest),
          equals(legacyCodec.encodedStreamDigestSize(digest)),
        );
      },
    );
  });
}
