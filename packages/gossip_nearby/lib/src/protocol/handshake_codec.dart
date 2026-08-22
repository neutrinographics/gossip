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

/// Result of decoding a handshake message.
class HandshakeData {
  final NodeId nodeId;
  final String? displayName;

  const HandshakeData({required this.nodeId, this.displayName});
}

/// Codec for encoding and decoding handshake messages.
///
/// Wire format (v2 with display name):
/// [0x01][nodeIdLen:4][nodeId:UTF-8][displayNameLen:4][displayName:UTF-8]
///
/// Backward compatible: old clients read nodeId and ignore the rest.
class HandshakeCodec {
  const HandshakeCodec();

  /// Encodes a handshake message containing the local NodeId and display name.
  Uint8List encode(NodeId nodeId, {String? displayName}) {
    final nodeIdBytes = utf8.encode(nodeId.value);
    final displayNameBytes = displayName != null
        ? utf8.encode(displayName)
        : Uint8List(0);

    final totalLength =
        WireFormat.handshakeHeaderSize +
        nodeIdBytes.length +
        WireFormat.lengthFieldSize +
        displayNameBytes.length;

    final buffer = ByteData(totalLength);
    var offset = 0;

    // Message type
    buffer.setUint8(offset, MessageType.handshake);
    offset += 1;

    // NodeId length + bytes
    buffer.setUint32(offset, nodeIdBytes.length, Endian.big);
    offset += WireFormat.lengthFieldSize;

    final result = buffer.buffer.asUint8List();
    result.setRange(offset, offset + nodeIdBytes.length, nodeIdBytes);
    offset += nodeIdBytes.length;

    // Display name length + bytes
    buffer.setUint32(offset, displayNameBytes.length, Endian.big);
    offset += WireFormat.lengthFieldSize;
    result.setRange(offset, offset + displayNameBytes.length, displayNameBytes);

    return result;
  }

  /// Decodes a handshake message to extract the remote NodeId and display name.
  ///
  /// Returns null if the message is malformed or contains an invalid NodeId.
  HandshakeData? decode(Uint8List bytes) {
    if (bytes.length < WireFormat.handshakeHeaderSize) return null;
    if (bytes[WireFormat.typeOffset] != MessageType.handshake) return null;

    final buffer = ByteData.sublistView(bytes);
    var offset = WireFormat.lengthOffset;

    // Read nodeId
    final nodeIdLength = buffer.getUint32(offset, Endian.big);
    offset += WireFormat.lengthFieldSize;

    if (bytes.length < offset + nodeIdLength) return null;

    final nodeIdBytes = bytes.sublist(offset, offset + nodeIdLength);
    offset += nodeIdLength;

    final nodeIdValue = utf8.decode(nodeIdBytes);
    final NodeId nodeId;
    try {
      nodeId = NodeId(nodeIdValue);
    } on ArgumentError {
      return null;
    }

    // Read display name (optional - may not be present in old handshakes)
    String? displayName;
    if (bytes.length >= offset + WireFormat.lengthFieldSize) {
      final displayNameLength = buffer.getUint32(offset, Endian.big);
      offset += WireFormat.lengthFieldSize;

      if (bytes.length >= offset + displayNameLength && displayNameLength > 0) {
        final displayNameBytes = bytes.sublist(
          offset,
          offset + displayNameLength,
        );
        displayName = utf8.decode(displayNameBytes);
      }
    }

    return HandshakeData(nodeId: nodeId, displayName: displayName);
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
