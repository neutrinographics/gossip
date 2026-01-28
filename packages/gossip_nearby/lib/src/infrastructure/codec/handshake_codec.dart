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

/// Wire format layout constants.
abstract class WireFormat {
  /// Byte offset where the message type is stored.
  static const int typeOffset = 0;

  /// Byte offset where the length field begins (handshake messages only).
  static const int lengthOffset = 1;

  /// Size of the length field in bytes.
  static const int lengthFieldSize = 4;

  /// Total header size for handshake messages (type + length).
  static const int handshakeHeaderSize = 1 + lengthFieldSize;

  /// Byte offset where the payload begins in handshake messages.
  static const int handshakePayloadOffset = handshakeHeaderSize;

  /// Byte offset where the payload begins in gossip messages.
  static const int gossipPayloadOffset = 1;
}

/// Codec for encoding and decoding handshake messages.
///
/// Wire format: [0x01][length:4 bytes][nodeId:UTF-8 bytes]
class HandshakeCodec {
  const HandshakeCodec();

  /// Encodes a handshake message containing the local NodeId.
  Uint8List encode(NodeId nodeId) {
    final nodeIdBytes = utf8.encode(nodeId.value);
    final totalLength = WireFormat.handshakeHeaderSize + nodeIdBytes.length;
    final buffer = ByteData(totalLength);
    buffer.setUint8(WireFormat.typeOffset, MessageType.handshake);
    buffer.setUint32(WireFormat.lengthOffset, nodeIdBytes.length, Endian.big);
    final result = buffer.buffer.asUint8List();
    result.setRange(
      WireFormat.handshakePayloadOffset,
      WireFormat.handshakePayloadOffset + nodeIdBytes.length,
      nodeIdBytes,
    );
    return result;
  }

  /// Decodes a handshake message to extract the remote NodeId.
  ///
  /// Returns null if the message is malformed or contains an invalid NodeId.
  NodeId? decode(Uint8List bytes) {
    if (bytes.length < WireFormat.handshakeHeaderSize) return null;
    if (bytes[WireFormat.typeOffset] != MessageType.handshake) return null;

    final buffer = ByteData.sublistView(bytes);
    final payloadLength = buffer.getUint32(WireFormat.lengthOffset, Endian.big);
    final expectedLength = WireFormat.handshakeHeaderSize + payloadLength;
    if (bytes.length < expectedLength) return null;

    final nodeIdBytes = bytes.sublist(
      WireFormat.handshakePayloadOffset,
      WireFormat.handshakePayloadOffset + payloadLength,
    );
    final nodeIdValue = utf8.decode(nodeIdBytes);

    try {
      return NodeId(nodeIdValue);
    } on ArgumentError {
      return null;
    }
  }

  /// Wraps a gossip payload with the gossip message type prefix.
  Uint8List wrapGossipMessage(Uint8List payload) {
    final result = Uint8List(WireFormat.gossipPayloadOffset + payload.length);
    result[WireFormat.typeOffset] = MessageType.gossip;
    result.setRange(
      WireFormat.gossipPayloadOffset,
      WireFormat.gossipPayloadOffset + payload.length,
      payload,
    );
    return result;
  }

  /// Unwraps a gossip message, removing the type prefix.
  ///
  /// Returns null if not a gossip message.
  Uint8List? unwrapGossipMessage(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    if (bytes[WireFormat.typeOffset] != MessageType.gossip) return null;
    return bytes.sublist(WireFormat.gossipPayloadOffset);
  }
}
