import 'dart:convert';
import 'dart:typed_data';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

void main() {
  final codec = ProtocolCodec();

  DeltaResponse responseWith(List<LogEntry> entries) => DeltaResponse(
    sender: NodeId('sender'),
    channelId: ChannelId('ch1'),
    streamId: StreamId('s1'),
    entries: entries,
  );

  Map<String, dynamic> jsonOf(Uint8List encoded) =>
      jsonDecode(utf8.decode(encoded.sublist(1))) as Map<String, dynamic>;

  group('ProtocolCodec payload encoding', () {
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
      final maxPayload = ProtocolCodec.maxEntryPayloadForBudget(budget);

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

    test('rejects legacy payload bytes outside 0-255 instead of truncating', () {
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
    });
  });
}
