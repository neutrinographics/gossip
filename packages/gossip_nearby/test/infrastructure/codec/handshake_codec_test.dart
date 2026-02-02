import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/src/infrastructure/codec/handshake_codec.dart';

void main() {
  group('HandshakeCodec', () {
    const codec = HandshakeCodec();

    group('encode/decode handshake', () {
      test('round-trips a NodeId', () {
        final nodeId = NodeId('test-node-123');

        final encoded = codec.encode(nodeId);
        final decoded = codec.decode(encoded);

        expect(decoded, isNotNull);
        expect(decoded!.nodeId, equals(nodeId));
        expect(decoded.displayName, isNull);
      });

      test('round-trips a NodeId with display name', () {
        final nodeId = NodeId('test-node-123');
        const displayName = 'Test Device';

        final encoded = codec.encode(nodeId, displayName: displayName);
        final decoded = codec.decode(encoded);

        expect(decoded, isNotNull);
        expect(decoded!.nodeId, equals(nodeId));
        expect(decoded.displayName, equals(displayName));
      });

      test('encodes with correct message type prefix', () {
        final nodeId = NodeId('test');
        final encoded = codec.encode(nodeId);

        expect(encoded[0], equals(MessageType.handshake));
      });

      test('encodes length as 4-byte big-endian', () {
        final nodeId = NodeId('test'); // 4 bytes
        final encoded = codec.encode(nodeId);

        final buffer = ByteData.sublistView(encoded);
        final length = buffer.getUint32(1, Endian.big);

        expect(length, equals(4));
      });

      test('decode returns null for empty string NodeId', () {
        // NodeId validates non-empty, so decoding an empty value should fail
        // Format: [type][nodeIdLen=0][displayNameLen=0]
        final encoded = Uint8List.fromList([0x01, 0, 0, 0, 0, 0, 0, 0, 0]);
        final decoded = codec.decode(encoded);

        // NodeId constructor throws on empty, so decode should return null
        expect(decoded, isNull);
      });

      test('handles unicode NodeId', () {
        final nodeId = NodeId('nöde-émoji-🎉');

        final encoded = codec.encode(nodeId);
        final decoded = codec.decode(encoded);

        expect(decoded, isNotNull);
        expect(decoded!.nodeId, equals(nodeId));
      });

      test('handles unicode display name', () {
        final nodeId = NodeId('test-node');
        const displayName = 'Tëst Dévice 🎉';

        final encoded = codec.encode(nodeId, displayName: displayName);
        final decoded = codec.decode(encoded);

        expect(decoded, isNotNull);
        expect(decoded!.nodeId, equals(nodeId));
        expect(decoded.displayName, equals(displayName));
      });

      test('decode returns null for empty bytes', () {
        final decoded = codec.decode(Uint8List(0));

        expect(decoded, isNull);
      });

      test('decode returns null for bytes too short', () {
        final decoded = codec.decode(Uint8List.fromList([0x01, 0, 0]));

        expect(decoded, isNull);
      });

      test('decode returns null for wrong message type', () {
        final decoded = codec.decode(
          Uint8List.fromList([0x02, 0, 0, 0, 4, 116, 101, 115, 116]),
        );

        expect(decoded, isNull);
      });

      test('decode returns null for truncated payload', () {
        // Header says 10 bytes but only 4 provided
        final decoded = codec.decode(
          Uint8List.fromList([0x01, 0, 0, 0, 10, 116, 101, 115, 116]),
        );

        expect(decoded, isNull);
      });
    });

    group('wrapGossipMessage/unwrapGossipMessage', () {
      test('round-trips a gossip payload', () {
        final payload = Uint8List.fromList([1, 2, 3, 4, 5]);

        final wrapped = codec.wrapGossipMessage(payload);
        final unwrapped = codec.unwrapGossipMessage(wrapped);

        expect(unwrapped, equals(payload));
      });

      test('wrap adds gossip message type prefix', () {
        final payload = Uint8List.fromList([1, 2, 3]);
        final wrapped = codec.wrapGossipMessage(payload);

        expect(wrapped[0], equals(MessageType.gossip));
        expect(wrapped.sublist(1), equals(payload));
      });

      test('unwrap returns null for empty bytes', () {
        final unwrapped = codec.unwrapGossipMessage(Uint8List(0));

        expect(unwrapped, isNull);
      });

      test('unwrap returns null for wrong message type', () {
        final unwrapped = codec.unwrapGossipMessage(
          Uint8List.fromList([0x01, 1, 2, 3]),
        );

        expect(unwrapped, isNull);
      });

      test('unwrap handles empty payload', () {
        final wrapped = Uint8List.fromList([MessageType.gossip]);
        final unwrapped = codec.unwrapGossipMessage(wrapped);

        expect(unwrapped, equals(Uint8List(0)));
      });
    });
  });

  group('MessageType', () {
    test('handshake is 0x01', () {
      expect(MessageType.handshake, equals(0x01));
    });

    test('gossip is 0x02', () {
      expect(MessageType.gossip, equals(0x02));
    });
  });
}
