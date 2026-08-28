import 'dart:convert';
import 'dart:typed_data';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/interfaces/protocol_message.dart';
import 'package:gossip/src/membership/domain/messages/ping.dart';
import 'package:gossip/src/membership/domain/messages/ack.dart';
import 'package:gossip/src/membership/domain/messages/ping_req.dart';
import 'package:gossip/src/shared/domain/interfaces/message_codec.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_types.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';

/// Wire codec for the membership context's SWIM messages: [Ping], [Ack],
/// [PingReq] — [WireTypes.membership] type bytes 0-2.
///
/// Wire format: `[Type Byte][JSON Payload]` (v1) or
/// `[0xF2][Type Byte][JSON Payload]` (v2, [WireVersion.v2]). The JSON
/// payload schema is identical in both versions, so unlike the sync
/// codec there are no per-version emission modules — [wireVersion] only
/// selects whether [encode] emits the marker; [decode] always accepts
/// both framings and returns null when the type byte belongs to the sync
/// family, so callers can fall through to `SyncMessageCodec`.
class MembershipMessageCodec implements MessageCodec {
  MembershipMessageCodec({required this.wireVersion});

  /// The dialect this codec EMITS; decode always accepts both.
  final WireVersion wireVersion;

  @override
  Uint8List encode(ProtocolMessage message) {
    final messageType = _getMessageType(message);
    final data = _encodeMessageData(message);

    final prefix = wireVersion == WireVersion.v2
        ? [WireTypes.markerV2, messageType]
        : [messageType];
    final result = Uint8List(prefix.length + data.length);
    result.setRange(0, prefix.length, prefix);
    result.setRange(prefix.length, result.length, data);
    return result;
  }

  @override
  ProtocolMessage? decode(Uint8List bytes) {
    final offset = WireTypes.frameTypeOffset(bytes);
    final messageType = bytes[offset];
    if (!WireTypes.membership.contains(messageType)) {
      // A byte owned by a sibling context (sync) is routine "not mine"
      // traffic sharing the transport; a byte owned by NO known context is
      // a genuinely corrupt frame and must surface as an error rather than
      // being silently dropped as if it were healthy foreign traffic.
      if (!WireTypes.known.contains(messageType)) {
        throw ArgumentError('Unknown message type: $messageType');
      }
      return null;
    }
    return _decodeMessageData(messageType, bytes.sublist(offset + 1));
  }

  int _getMessageType(ProtocolMessage message) {
    if (message is Ping) return WireTypes.ping;
    if (message is Ack) return WireTypes.ack;
    if (message is PingReq) return WireTypes.pingReq;
    throw ArgumentError('Unknown message type: ${message.runtimeType}');
  }

  Uint8List _encodeMessageData(ProtocolMessage message) {
    final Map<String, dynamic> json;

    if (message is Ping) {
      json = _encodePing(message);
    } else if (message is Ack) {
      json = _encodeAck(message);
    } else if (message is PingReq) {
      json = _encodePingReq(message);
    } else {
      throw ArgumentError('Unknown message type: ${message.runtimeType}');
    }

    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  Map<String, dynamic> _encodePing(Ping message) {
    return {'sender': message.sender.value, 'sequence': message.sequence};
  }

  Map<String, dynamic> _encodeAck(Ack message) {
    return {'sender': message.sender.value, 'sequence': message.sequence};
  }

  Map<String, dynamic> _encodePingReq(PingReq message) {
    return {
      'sender': message.sender.value,
      'sequence': message.sequence,
      'target': message.target.value,
    };
  }

  ProtocolMessage _decodeMessageData(int messageType, Uint8List data) {
    final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;

    switch (messageType) {
      case WireTypes.ping:
        return _decodePing(json);
      case WireTypes.ack:
        return _decodeAck(json);
      case WireTypes.pingReq:
        return _decodePingReq(json);
      default:
        throw ArgumentError('Unknown message type: $messageType');
    }
  }

  Ping _decodePing(Map<String, dynamic> json) {
    return Ping(
      sender: NodeId(json['sender'] as String),
      sequence: json['sequence'] as int,
    );
  }

  Ack _decodeAck(Map<String, dynamic> json) {
    return Ack(
      sender: NodeId(json['sender'] as String),
      sequence: json['sequence'] as int,
    );
  }

  PingReq _decodePingReq(Map<String, dynamic> json) {
    return PingReq(
      sender: NodeId(json['sender'] as String),
      sequence: json['sequence'] as int,
      target: NodeId(json['target'] as String),
    );
  }
}
