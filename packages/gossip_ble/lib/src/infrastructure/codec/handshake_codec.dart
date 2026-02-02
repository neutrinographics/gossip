import 'dart:convert';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../domain/ports/handshake_codec_port.dart';

// Re-export MessageType from domain for backwards compatibility
export '../../domain/ports/handshake_codec_port.dart' show MessageType;

/// Wire format layout constants.
abstract class _WireFormat {
  static const int typeOffset = 0;
  static const int lengthOffset = 1;
  static const int lengthFieldSize = 4;
  static const int handshakeHeaderSize = 1 + lengthFieldSize;
  static const int handshakePayloadOffset = handshakeHeaderSize;
  static const int gossipPayloadOffset = 1;
}

/// Codec for encoding and decoding handshake and gossip messages.
///
/// Handshake wire format: [0x01][length:4 bytes][nodeId:UTF-8 bytes]
/// Gossip wire format: [0x02][payload bytes]
class HandshakeCodec implements HandshakeCodecPort {
  const HandshakeCodec();

  @override
  Uint8List encodeHandshake(NodeId nodeId) {
    final nodeIdBytes = utf8.encode(nodeId.value);
    final totalLength = _WireFormat.handshakeHeaderSize + nodeIdBytes.length;
    final buffer = ByteData(totalLength);
    buffer.setUint8(_WireFormat.typeOffset, MessageType.handshake);
    buffer.setUint32(_WireFormat.lengthOffset, nodeIdBytes.length, Endian.big);
    final result = buffer.buffer.asUint8List();
    result.setRange(
      _WireFormat.handshakePayloadOffset,
      _WireFormat.handshakePayloadOffset + nodeIdBytes.length,
      nodeIdBytes,
    );
    return result;
  }

  @override
  NodeId? decodeHandshake(Uint8List bytes) {
    if (bytes.length < _WireFormat.handshakeHeaderSize) return null;
    if (bytes[_WireFormat.typeOffset] != MessageType.handshake) return null;

    final buffer = ByteData.sublistView(bytes);
    final payloadLength = buffer.getUint32(
      _WireFormat.lengthOffset,
      Endian.big,
    );
    final expectedLength = _WireFormat.handshakeHeaderSize + payloadLength;
    if (bytes.length < expectedLength) return null;

    // Reject empty NodeId
    if (payloadLength == 0) return null;

    final nodeIdBytes = bytes.sublist(
      _WireFormat.handshakePayloadOffset,
      _WireFormat.handshakePayloadOffset + payloadLength,
    );

    // Safely decode UTF-8, returning null on invalid bytes
    final String nodeIdValue;
    try {
      nodeIdValue = utf8.decode(nodeIdBytes);
    } on FormatException {
      return null;
    }

    // Validate non-empty after decode (handles whitespace-only strings)
    if (nodeIdValue.trim().isEmpty) return null;

    // Safely create NodeId, catching validation errors
    try {
      return NodeId(nodeIdValue);
    } on ArgumentError {
      return null;
    }
  }

  @override
  Uint8List wrapGossip(Uint8List payload) {
    final result = Uint8List(_WireFormat.gossipPayloadOffset + payload.length);
    result[_WireFormat.typeOffset] = MessageType.gossip;
    result.setRange(
      _WireFormat.gossipPayloadOffset,
      _WireFormat.gossipPayloadOffset + payload.length,
      payload,
    );
    return result;
  }

  @override
  Uint8List? unwrapGossip(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    if (bytes[_WireFormat.typeOffset] != MessageType.gossip) return null;
    return bytes.sublist(_WireFormat.gossipPayloadOffset);
  }

  @override
  int? getMessageType(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    return bytes[_WireFormat.typeOffset];
  }
}
