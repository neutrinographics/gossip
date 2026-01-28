import 'dart:convert';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

/// Wire format constants for message types.
abstract class MessageType {
  /// Handshake message: [0x01][length:4 bytes][nodeId:UTF-8 bytes]
  static const int handshake = 0x01;

  /// Gossip message: [0x02][payload bytes]
  static const int gossip = 0x02;
}

/// Codec for encoding and decoding handshake messages.
///
/// Wire format: [0x01][length:4 bytes][nodeId:UTF-8 bytes]
class HandshakeCodec {
  const HandshakeCodec();

  /// Encodes a handshake message containing the local NodeId.
  Uint8List encode(NodeId nodeId) {
    final nodeIdBytes = utf8.encode(nodeId.value);
    final buffer = ByteData(5 + nodeIdBytes.length);
    buffer.setUint8(0, MessageType.handshake);
    buffer.setUint32(1, nodeIdBytes.length, Endian.big);
    final result = buffer.buffer.asUint8List();
    result.setRange(5, 5 + nodeIdBytes.length, nodeIdBytes);
    return result;
  }

  /// Decodes a handshake message to extract the remote NodeId.
  ///
  /// Returns null if the message is malformed or contains an invalid NodeId.
  NodeId? decode(Uint8List bytes) {
    if (bytes.length < 5) return null;
    if (bytes[0] != MessageType.handshake) return null;

    final buffer = ByteData.sublistView(bytes);
    final length = buffer.getUint32(1, Endian.big);
    if (bytes.length < 5 + length) return null;

    final nodeIdBytes = bytes.sublist(5, 5 + length);
    final nodeIdValue = utf8.decode(nodeIdBytes);

    try {
      return NodeId(nodeIdValue);
    } on ArgumentError {
      return null;
    }
  }

  /// Wraps a gossip payload with the gossip message type prefix.
  Uint8List wrapGossipMessage(Uint8List payload) {
    final result = Uint8List(1 + payload.length);
    result[0] = MessageType.gossip;
    result.setRange(1, 1 + payload.length, payload);
    return result;
  }

  /// Unwraps a gossip message, removing the type prefix.
  ///
  /// Returns null if not a gossip message.
  Uint8List? unwrapGossipMessage(Uint8List bytes) {
    if (bytes.isEmpty || bytes[0] != MessageType.gossip) return null;
    return bytes.sublist(1);
  }
}
