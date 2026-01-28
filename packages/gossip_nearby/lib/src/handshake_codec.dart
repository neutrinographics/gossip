import 'dart:convert';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

/// Codec for the handshake protocol messages.
///
/// The handshake is a simple exchange:
/// 1. Both sides send their NodeId immediately after connection
/// 2. Both sides wait to receive the other's NodeId
/// 3. Once both NodeIds are exchanged, the connection is "ready"
///
/// Wire format:
/// - [0]: Message type (0x01 = handshake)
/// - [1-4]: NodeId length (big-endian uint32)
/// - [5+]: NodeId value (UTF-8 encoded)
class HandshakeCodec {
  static const int _handshakeType = 0x01;
  static const int _gossipMessageType = 0x02;

  /// Encodes a handshake message containing the local NodeId.
  static Uint8List encodeHandshake(NodeId nodeId) {
    final nodeIdBytes = utf8.encode(nodeId.value);
    final buffer = ByteData(5 + nodeIdBytes.length);

    buffer.setUint8(0, _handshakeType);
    buffer.setUint32(1, nodeIdBytes.length, Endian.big);

    final result = buffer.buffer.asUint8List();
    result.setRange(5, 5 + nodeIdBytes.length, nodeIdBytes);

    return result;
  }

  /// Decodes a handshake message, returning the remote NodeId.
  ///
  /// Returns null if the message is not a valid handshake.
  static NodeId? decodeHandshake(Uint8List bytes) {
    if (bytes.length < 5) return null;

    final buffer = ByteData.sublistView(bytes);
    final type = buffer.getUint8(0);
    if (type != _handshakeType) return null;

    final length = buffer.getUint32(1, Endian.big);
    if (bytes.length < 5 + length) return null;

    final nodeIdBytes = bytes.sublist(5, 5 + length);
    final nodeIdValue = utf8.decode(nodeIdBytes);

    return NodeId(nodeIdValue);
  }

  /// Wraps gossip protocol bytes for transport.
  ///
  /// Adds a type prefix to distinguish from handshake messages.
  static Uint8List wrapGossipMessage(Uint8List payload) {
    final result = Uint8List(1 + payload.length);
    result[0] = _gossipMessageType;
    result.setRange(1, 1 + payload.length, payload);
    return result;
  }

  /// Unwraps gossip protocol bytes.
  ///
  /// Returns null if not a gossip message (e.g., it's a handshake).
  static Uint8List? unwrapGossipMessage(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    if (bytes[0] != _gossipMessageType) return null;
    return bytes.sublist(1);
  }

  /// Checks if bytes represent a handshake message.
  static bool isHandshake(Uint8List bytes) {
    return bytes.isNotEmpty && bytes[0] == _handshakeType;
  }

  /// Checks if bytes represent a gossip message.
  static bool isGossipMessage(Uint8List bytes) {
    return bytes.isNotEmpty && bytes[0] == _gossipMessageType;
  }
}
