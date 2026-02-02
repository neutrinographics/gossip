import 'dart:typed_data';

import 'package:gossip/gossip.dart';

/// Wire format constants for message types.
///
/// These are domain concepts representing the protocol-level message types
/// used in BLE communication.
abstract class MessageType {
  /// Handshake message containing a NodeId.
  static const int handshake = 0x01;

  /// Gossip message containing application payload.
  static const int gossip = 0x02;
}

/// Port interface for encoding/decoding handshake and gossip messages.
///
/// This is a domain port that defines the contract for wire format encoding.
/// Infrastructure implementations handle the actual byte manipulation.
abstract class HandshakeCodecPort {
  /// Encodes a handshake message containing the local NodeId.
  Uint8List encodeHandshake(NodeId nodeId);

  /// Decodes a handshake message to extract the remote NodeId.
  ///
  /// Returns null if the message is malformed.
  NodeId? decodeHandshake(Uint8List bytes);

  /// Wraps a gossip payload with the gossip message type prefix.
  Uint8List wrapGossip(Uint8List payload);

  /// Unwraps a gossip message, removing the type prefix.
  ///
  /// Returns null if not a gossip message.
  Uint8List? unwrapGossip(Uint8List bytes);

  /// Gets the message type from raw bytes.
  ///
  /// Returns null if bytes are empty.
  int? getMessageType(Uint8List bytes);
}
