import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_ble/src/infrastructure/codec/handshake_codec.dart';

void main() {
  group('HandshakeCodec', () {
    const codec = HandshakeCodec();

    group('encode/decode handshake', () {
      test('encodes and decodes NodeId correctly', () {
        final nodeId = NodeId('test-node-123');

        final encoded = codec.encodeHandshake(nodeId);
        final decoded = codec.decodeHandshake(encoded);

        expect(decoded, isNotNull);
        expect(decoded!.value, 'test-node-123');
      });

      test('encoded message starts with handshake type', () {
        final nodeId = NodeId('test-node');
        final encoded = codec.encodeHandshake(nodeId);

        expect(encoded[0], MessageType.handshake);
      });

      test('handles long NodeId', () {
        final longValue = 'a' * 1000;
        final nodeId = NodeId(longValue);

        final encoded = codec.encodeHandshake(nodeId);
        final decoded = codec.decodeHandshake(encoded);

        expect(decoded, isNotNull);
        expect(decoded!.value, longValue);
      });

      test('handles unicode NodeId', () {
        final nodeId = NodeId('node-日本語-🎉');

        final encoded = codec.encodeHandshake(nodeId);
        final decoded = codec.decodeHandshake(encoded);

        expect(decoded, isNotNull);
        expect(decoded!.value, 'node-日本語-🎉');
      });

      test('decode returns null for empty bytes', () {
        final decoded = codec.decodeHandshake(Uint8List(0));
        expect(decoded, isNull);
      });

      test('decode returns null for truncated header', () {
        final decoded = codec.decodeHandshake(Uint8List.fromList([0x01, 0x00]));
        expect(decoded, isNull);
      });

      test('decode returns null for wrong message type', () {
        final bytes = Uint8List.fromList([
          0x02,
          0x00,
          0x00,
          0x00,
          0x04,
          0x74,
          0x65,
          0x73,
          0x74,
        ]);
        final decoded = codec.decodeHandshake(bytes);
        expect(decoded, isNull);
      });

      test('decode returns null for truncated payload', () {
        // Header claims 100 bytes but only provides 4
        final bytes = Uint8List.fromList([
          0x01,
          0x00,
          0x00,
          0x00,
          0x64,
          0x74,
          0x65,
          0x73,
          0x74,
        ]);
        final decoded = codec.decodeHandshake(bytes);
        expect(decoded, isNull);
      });
    });

    group('wrap/unwrap gossip', () {
      test('wraps and unwraps gossip payload correctly', () {
        final payload = Uint8List.fromList([1, 2, 3, 4, 5]);

        final wrapped = codec.wrapGossip(payload);
        final unwrapped = codec.unwrapGossip(wrapped);

        expect(unwrapped, isNotNull);
        expect(unwrapped, payload);
      });

      test('wrapped message starts with gossip type', () {
        final payload = Uint8List.fromList([1, 2, 3]);
        final wrapped = codec.wrapGossip(payload);

        expect(wrapped[0], MessageType.gossip);
      });

      test('handles empty payload', () {
        final payload = Uint8List(0);

        final wrapped = codec.wrapGossip(payload);
        final unwrapped = codec.unwrapGossip(wrapped);

        expect(unwrapped, isNotNull);
        expect(unwrapped, isEmpty);
      });

      test('unwrap returns null for empty bytes', () {
        final unwrapped = codec.unwrapGossip(Uint8List(0));
        expect(unwrapped, isNull);
      });

      test('unwrap returns null for wrong message type', () {
        final bytes = Uint8List.fromList([0x01, 0x01, 0x02, 0x03]);
        final unwrapped = codec.unwrapGossip(bytes);
        expect(unwrapped, isNull);
      });
    });

    group('getMessageType', () {
      test('returns handshake type for handshake message', () {
        final nodeId = NodeId('test');
        final encoded = codec.encodeHandshake(nodeId);

        expect(codec.getMessageType(encoded), MessageType.handshake);
      });

      test('returns gossip type for gossip message', () {
        final wrapped = codec.wrapGossip(Uint8List.fromList([1, 2, 3]));

        expect(codec.getMessageType(wrapped), MessageType.gossip);
      });

      test('returns null for empty bytes', () {
        expect(codec.getMessageType(Uint8List(0)), isNull);
      });
    });
  });
}
