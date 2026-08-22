import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/src/protocol/handshake_codec.dart';
import 'package:gossip_nearby/src/protocol/wire_dispatcher.dart';

/// ARCH3-3: byte-layout knowledge (WireFormat.typeOffset) executes in the
/// protocol layer; the application layer switches on MessageType only.
///
/// [MessageType] is a namespace of `static const int` wire values (not a
/// Dart `enum`), so there is no `MessageType.values` to iterate. The known
/// wire values are exactly the ones `ConnectionService`'s dispatch site
/// handles today: [MessageType.handshake] and [MessageType.gossip]. Any
/// other byte falls to that site's `default:` branch and is not a
/// classifiable "type" — it is covered separately below.
const codec = HandshakeCodec();

/// Builds the smallest valid frame whose type byte is `type`, mirroring the
/// frame construction in handshake_codec_test.dart (the byte-layout source
/// of truth): [HandshakeCodec.encode] for a handshake frame,
/// [HandshakeCodec.wrapGossipMessage] for a gossip frame.
Uint8List buildFrameWithType(int type) {
  switch (type) {
    case MessageType.handshake:
      return codec.encode(NodeId('wire-dispatcher-test-node'));
    case MessageType.gossip:
      return codec.wrapGossipMessage(Uint8List.fromList([1, 2, 3]));
    default:
      throw ArgumentError('No frame builder for message type $type');
  }
}

void main() {
  group('WireDispatcher', () {
    test('classifies each MessageType round-tripped through the wire byte', () {
      final dispatcher = WireDispatcher();
      for (final type in [MessageType.handshake, MessageType.gossip]) {
        final bytes = buildFrameWithType(type);
        expect(
          dispatcher.classify(bytes),
          type,
          reason:
              'the dispatcher must agree with the codec about '
              'where the type byte lives',
        );
      }
    });

    test('classifies an unknown type byte as-is (caller handles default)', () {
      final dispatcher = WireDispatcher();
      final bytes = Uint8List.fromList([0xFF, 1, 2, 3]);

      expect(dispatcher.classify(bytes), equals(0xFF));
    });
  });
}
