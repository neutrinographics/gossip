import 'dart:convert';
import 'dart:typed_data';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/protocol/messages/protocol_message.dart';
import 'package:gossip/src/protocol/messages/ping.dart';
import 'package:gossip/src/protocol/messages/ack.dart';
import 'package:gossip/src/protocol/messages/ping_req.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';
import 'package:gossip/src/protocol/messages/delta_request.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:gossip/src/protocol/values/stream_digest.dart';

/// Serializes protocol messages to wire format and deserializes them back.
///
/// [ProtocolCodec] handles the conversion between [ProtocolMessage] objects
/// and byte arrays suitable for network transmission. This enables the gossip
/// protocol to work with any transport mechanism (TCP, UDP, Bluetooth, etc.).
///
/// ## Wire Format
/// Messages are encoded using a simple two-part structure:
/// ```
/// [Type Byte][JSON Payload]
/// ```
///
/// - **Byte 0 (Type)**: Message type identifier (0-6)
/// - **Bytes 1+**: UTF-8 encoded JSON containing message fields
///
/// ## Message Types
/// - 0: Ping (SWIM direct probe)
/// - 1: Ack (SWIM acknowledgment)
/// - 2: PingReq (SWIM indirect probe)
/// - 3: DigestRequest (gossip anti-entropy initiation)
/// - 4: DigestResponse (gossip digest exchange)
/// - 5: DeltaRequest (request for missing entries)
/// - 6: DeltaResponse (delivery of missing entries)
///
/// ## Design Rationale
/// - **Type byte**: Enables fast message type discrimination without parsing JSON
/// - **JSON payload**: Simple, debuggable, and compatible with all platforms
/// - **UTF-8 encoding**: Standard text encoding supported everywhere
///
/// ## Size Constraints
/// The codec doesn't enforce size limits. Applications should ensure messages
/// stay under transport limits (e.g., 32KB for Android Nearby Connections).
class ProtocolCodec {
  // Message type constants for wire format
  static const int _typePing = 0;
  static const int _typeAck = 1;
  static const int _typePingReq = 2;
  static const int _typeDigestRequest = 3;
  static const int _typeDigestResponse = 4;
  static const int _typeDeltaRequest = 5;
  static const int _typeDeltaResponse = 6;

  /// Encodes a protocol message to bytes for wire transmission.
  ///
  /// Returns a byte array where:
  /// - Byte 0: Message type identifier
  /// - Remaining bytes: UTF-8 JSON-encoded message fields
  ///
  /// Throws [ArgumentError] if the message type is unknown.
  Uint8List encode(ProtocolMessage message) {
    final messageType = _getMessageType(message);
    final data = _encodeMessageData(message);

    final result = Uint8List(1 + data.length);
    result[0] = messageType;
    result.setRange(1, result.length, data);
    return result;
  }

  /// Decodes bytes from wire format to a protocol message.
  ///
  /// Reads the type byte to determine message type, then deserializes
  /// the JSON payload into the appropriate [ProtocolMessage] subclass.
  ///
  /// Throws [ArgumentError] if:
  /// - bytes is empty
  /// - message type is unknown
  /// - JSON payload is malformed
  ProtocolMessage decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw ArgumentError('Cannot decode empty bytes');
    }

    final messageType = bytes[0];
    final data = bytes.sublist(1);

    return _decodeMessageData(messageType, data);
  }

  int _getMessageType(ProtocolMessage message) {
    if (message is Ping) return _typePing;
    if (message is Ack) return _typeAck;
    if (message is PingReq) return _typePingReq;
    if (message is DigestRequest) return _typeDigestRequest;
    if (message is DigestResponse) return _typeDigestResponse;
    if (message is DeltaRequest) return _typeDeltaRequest;
    if (message is DeltaResponse) return _typeDeltaResponse;
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
    } else if (message is DigestRequest) {
      json = _encodeDigestRequest(message);
    } else if (message is DigestResponse) {
      json = _encodeDigestResponse(message);
    } else if (message is DeltaRequest) {
      json = _encodeDeltaRequest(message);
    } else if (message is DeltaResponse) {
      json = _encodeDeltaResponse(message);
    } else {
      throw ArgumentError('Unknown message type: ${message.runtimeType}');
    }

    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  // --- SWIM message encoders ---

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

  // --- Gossip message encoders ---

  Map<String, dynamic> _encodeDigestRequest(DigestRequest message) {
    return {
      'sender': message.sender.value,
      'digests': _encodeChannelDigests(message.digests),
    };
  }

  Map<String, dynamic> _encodeDigestResponse(DigestResponse message) {
    return {
      'sender': message.sender.value,
      'digests': _encodeChannelDigests(message.digests),
    };
  }

  Map<String, dynamic> _encodeDeltaRequest(DeltaRequest message) {
    return {
      'sender': message.sender.value,
      'channelId': message.channelId.value,
      'streamId': message.streamId.value,
      'since': _encodeVersionVector(message.since),
    };
  }

  Map<String, dynamic> _encodeDeltaResponse(DeltaResponse message) {
    return {
      'sender': message.sender.value,
      'channelId': message.channelId.value,
      'streamId': message.streamId.value,
      'entries': _encodeLogEntries(message.entries),
    };
  }

  // --- Shared value encoders ---

  List<Map<String, dynamic>> _encodeChannelDigests(
    List<ChannelDigest> digests,
  ) {
    return digests
        .map(
          (cd) => {
            'channelId': cd.channelId.value,
            'streams': _encodeStreamDigests(cd.streams),
          },
        )
        .toList();
  }

  List<Map<String, dynamic>> _encodeStreamDigests(List<StreamDigest> streams) {
    return streams
        .map(
          (sd) => {
            'streamId': sd.streamId.value,
            'version': _encodeVersionVector(sd.version),
          },
        )
        .toList();
  }

  Map<String, int> _encodeVersionVector(VersionVector version) {
    return version.entries.map((k, v) => MapEntry(k.value, v));
  }

  List<Map<String, dynamic>> _encodeLogEntries(List<LogEntry> entries) {
    return entries.map((entry) => _encodeLogEntry(entry)).toList();
  }

  Map<String, dynamic> _encodeLogEntry(LogEntry entry) {
    return {
      'author': entry.author.value,
      'sequence': entry.sequence,
      'timestamp': {
        'physicalMs': entry.timestamp.physicalMs,
        'logical': entry.timestamp.logical,
      },
      'payload': entry.payload.toList(),
    };
  }

  ProtocolMessage _decodeMessageData(int messageType, Uint8List data) {
    final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;

    switch (messageType) {
      case _typePing:
        return _decodePing(json);
      case _typeAck:
        return _decodeAck(json);
      case _typePingReq:
        return _decodePingReq(json);
      case _typeDigestRequest:
        return _decodeDigestRequest(json);
      case _typeDigestResponse:
        return _decodeDigestResponse(json);
      case _typeDeltaRequest:
        return _decodeDeltaRequest(json);
      case _typeDeltaResponse:
        return _decodeDeltaResponse(json);
      default:
        throw ArgumentError('Unknown message type: $messageType');
    }
  }

  // --- SWIM message decoders ---

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

  // --- Gossip message decoders ---

  DigestRequest _decodeDigestRequest(Map<String, dynamic> json) {
    return DigestRequest(
      sender: NodeId(json['sender'] as String),
      digests: _decodeChannelDigests(json['digests'] as List),
    );
  }

  DigestResponse _decodeDigestResponse(Map<String, dynamic> json) {
    return DigestResponse(
      sender: NodeId(json['sender'] as String),
      digests: _decodeChannelDigests(json['digests'] as List),
    );
  }

  DeltaRequest _decodeDeltaRequest(Map<String, dynamic> json) {
    return DeltaRequest(
      sender: NodeId(json['sender'] as String),
      channelId: ChannelId(json['channelId'] as String),
      streamId: StreamId(json['streamId'] as String),
      since: _decodeVersionVector(json['since'] as Map<String, dynamic>),
    );
  }

  DeltaResponse _decodeDeltaResponse(Map<String, dynamic> json) {
    return DeltaResponse(
      sender: NodeId(json['sender'] as String),
      channelId: ChannelId(json['channelId'] as String),
      streamId: StreamId(json['streamId'] as String),
      entries: _decodeLogEntries(json['entries'] as List),
    );
  }

  // --- Shared value decoders ---

  List<ChannelDigest> _decodeChannelDigests(List<dynamic> jsonList) {
    return jsonList.map((cdJson) {
      return ChannelDigest(
        channelId: ChannelId(cdJson['channelId'] as String),
        streams: _decodeStreamDigests(cdJson['streams'] as List),
      );
    }).toList();
  }

  List<StreamDigest> _decodeStreamDigests(List<dynamic> jsonList) {
    return jsonList.map((sdJson) {
      return StreamDigest(
        streamId: StreamId(sdJson['streamId'] as String),
        version: _decodeVersionVector(
          sdJson['version'] as Map<String, dynamic>,
        ),
      );
    }).toList();
  }

  VersionVector _decodeVersionVector(Map<String, dynamic> json) {
    final entries = json.map((k, v) => MapEntry(NodeId(k), v as int));
    return VersionVector(entries);
  }

  List<LogEntry> _decodeLogEntries(List<dynamic> jsonList) {
    return jsonList.map((entryJson) => _decodeLogEntry(entryJson)).toList();
  }

  LogEntry _decodeLogEntry(Map<String, dynamic> json) {
    final timestampJson = json['timestamp'] as Map<String, dynamic>;
    return LogEntry(
      author: NodeId(json['author'] as String),
      sequence: json['sequence'] as int,
      timestamp: Hlc(
        timestampJson['physicalMs'] as int,
        timestampJson['logical'] as int,
      ),
      payload: Uint8List.fromList((json['payload'] as List).cast<int>()),
    );
  }
}
