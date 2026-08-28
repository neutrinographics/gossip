import 'dart:convert';
import 'dart:typed_data';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';
import 'package:gossip/src/shared/domain/interfaces/protocol_message.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/messages/digest_response.dart';
import 'package:gossip/src/sync/domain/messages/delta_request.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';
import 'package:gossip/src/shared/domain/interfaces/message_codec.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_types.dart';
import 'package:gossip/src/sync/infrastructure/sync_wire_emission.dart';

/// Wire codec for the sync context's anti-entropy messages: [DigestRequest],
/// [DigestResponse], [DeltaRequest], [DeltaResponse] — [WireTypes.sync] type
/// bytes 3-6.
///
/// A version-dispatching facade: [wireVersion] selects the [SyncWireEmission]
/// strategy that governs everything [encode] does (framing, entry payload
/// shape, which fields are emitted). [decode] is version-agnostic — it
/// classifies the frame via [WireTypes.frameTypeOffset] and then accepts
/// either version's additive JSON shape, so a node that emits one version
/// still understands peers emitting the other. Returns null when the type
/// byte belongs to the membership family, so callers can fall through to
/// `MembershipMessageCodec`.
class SyncMessageCodec implements MessageCodec {
  SyncMessageCodec({required this.wireVersion})
    : _emission = switch (wireVersion) {
        WireVersion.v1 => const SyncEmissionV1(),
        WireVersion.v2 => const SyncEmissionV2(),
      };

  /// The dialect this codec EMITS; decode always accepts both.
  final WireVersion wireVersion;
  final SyncWireEmission _emission;

  @override
  Uint8List encode(ProtocolMessage message) {
    final messageType = _getMessageType(message);
    final Map<String, dynamic> json;

    if (message is DigestRequest) {
      json = _encodeDigestRequest(message);
    } else if (message is DigestResponse) {
      json = _encodeDigestResponse(message);
    } else if (message is DeltaRequest) {
      json = _encodeDeltaRequest(message);
    } else if (message is DeltaResponse) {
      json = _emission.deltaResponseJson(message);
    } else {
      throw ArgumentError('Unknown message type: ${message.runtimeType}');
    }

    return _emission.frame(messageType, utf8.encode(jsonEncode(json)));
  }

  @override
  ProtocolMessage? decode(Uint8List bytes) {
    final offset = WireTypes.frameTypeOffset(bytes);
    final messageType = bytes[offset];
    if (!WireTypes.sync.contains(messageType)) {
      // Sibling-family traffic is routine "not mine" in EVERY version;
      // a type byte no context owns is corruption in every version.
      if (!WireTypes.known.contains(messageType)) {
        throw ArgumentError('Unknown message type: $messageType');
      }
      return null;
    }
    return _decodeMessageData(messageType, bytes.sublist(offset + 1));
  }

  int _getMessageType(ProtocolMessage message) {
    if (message is DigestRequest) return WireTypes.digestRequest;
    if (message is DigestResponse) return WireTypes.digestResponse;
    if (message is DeltaRequest) return WireTypes.deltaRequest;
    if (message is DeltaResponse) return WireTypes.deltaResponse;
    throw ArgumentError('Unknown message type: ${message.runtimeType}');
  }

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
      'since': versionVectorJson(message.since),
    };
  }

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
            'version': versionVectorJson(sd.version),
          },
        )
        .toList();
  }

  /// Returns the encoded size in bytes of a single log entry as it would
  /// appear inside a message's `entries` array under the active
  /// [wireVersion].
  ///
  /// Used by the gossip engine to budget [DeltaResponse] messages against
  /// the transport size limit without repeatedly encoding whole messages.
  int encodedEntrySize(LogEntry entry) => _emission.encodedEntrySize(entry);

  /// Returns the encoded JSON size in bytes of a single [StreamDigest] as it
  /// appears inside a digest message's `streams` array.
  ///
  /// Digest schema is identical across versions, so this doesn't depend on
  /// [wireVersion].
  ///
  /// Used by the gossip engine to budget DigestRequest/DigestResponse
  /// messages against the transport limit without repeatedly encoding whole
  /// messages.
  int encodedStreamDigestSize(StreamDigest digest) {
    return utf8
        .encode(
          jsonEncode({
            'streamId': digest.streamId.value,
            'version': versionVectorJson(digest.version),
          }),
        )
        .length;
  }

  /// Conservative per-entry overhead in bytes: message envelope (sender,
  /// channelId, streamId) plus entry envelope (author, sequence, timestamp,
  /// JSON keys/punctuation). Sized for long node IDs and maximal HLC values.
  static const int _entryEnvelopeOverhead = 512;

  /// Largest entry payload (raw bytes) guaranteed to fit a [DeltaResponse]
  /// whose encoded size may not exceed [budgetBytes], under [version]'s
  /// payload encoding.
  ///
  /// Inverts the wire encoding for the given version — base64 (v2) turns 3
  /// payload bytes into 4 characters; the JSON int-array (v1) worst case
  /// spends 4 characters per payload byte (`"255,"`) — and
  /// [_entryEnvelopeOverhead] covers the JSON envelope. A payload larger
  /// than this can never be synced under the given budget and version —
  /// reject it at write time instead of livelocking at sync time.
  static int maxEntryPayloadForBudget(int budgetBytes, WireVersion version) {
    final usable = budgetBytes - _entryEnvelopeOverhead;
    if (usable <= 0) return 0;
    return switch (version) {
      WireVersion.v1 => usable ~/ 4,
      WireVersion.v2 => (usable ~/ 4) * 3,
    };
  }

  ProtocolMessage _decodeMessageData(int messageType, Uint8List data) {
    final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;

    switch (messageType) {
      case WireTypes.digestRequest:
        return _decodeDigestRequest(json);
      case WireTypes.digestResponse:
        return _decodeDigestResponse(json);
      case WireTypes.deltaRequest:
        return _decodeDeltaRequest(json);
      case WireTypes.deltaResponse:
        return _decodeDeltaResponse(json);
      default:
        throw ArgumentError('Unknown message type: $messageType');
    }
  }

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
    final floorJson = json['floor'] as Map<String, dynamic>?;
    return DeltaResponse(
      sender: NodeId(json['sender'] as String),
      channelId: ChannelId(json['channelId'] as String),
      streamId: StreamId(json['streamId'] as String),
      entries: _decodeLogEntries(json['entries'] as List),
      // Absent on legacy senders → defaults to false (no continuation).
      hasMore: json['hasMore'] as bool? ?? false,
      // Absent on legacy senders or when serviceable → empty.
      floor: floorJson == null
          ? VersionVector.empty
          : _decodeVersionVector(floorJson),
    );
  }

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
      payload: _decodePayload(json['payload']),
    );
  }

  /// Decodes an entry payload from its wire representation.
  ///
  /// Accepts the current base64 string format and the legacy JSON int-list
  /// format (for messages from older nodes or from senders that still emit
  /// unprefixed frames). The int-list reader tolerates elements from -128
  /// to 255 inclusive, normalizing negatives (`n + 256`): some deployed
  /// senders emit payload bytes as signed JSON ints, and a legacy decoder
  /// that rejected them would drop otherwise-valid traffic. Anything
  /// outside that range is genuine corruption and is rejected rather than
  /// silently truncated mod 256.
  Uint8List _decodePayload(Object? payload) {
    if (payload is String) {
      return base64Decode(payload);
    }
    if (payload is List) {
      final bytes = Uint8List(payload.length);
      for (var i = 0; i < payload.length; i++) {
        final b = payload[i];
        if (b is! int || b < -128 || b > 255) {
          throw ArgumentError('Invalid payload byte at index $i: $b');
        }
        bytes[i] = b < 0 ? b + 256 : b;
      }
      return bytes;
    }
    throw ArgumentError('Invalid payload type: ${payload.runtimeType}');
  }
}
