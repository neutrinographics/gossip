import 'dart:convert';
import 'dart:typed_data';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_types.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';

/// Shared JSON shape identical across wire versions: a version vector as
/// an author→sequence map.
Map<String, int> versionVectorJson(VersionVector version) =>
    version.entries.map((k, v) => MapEntry(k.value, v));

/// Shared JSON shape identical across wire versions: the non-payload
/// fields of a log entry.
Map<String, dynamic> entryEnvelopeJson(LogEntry entry) => {
  'author': entry.author.value,
  'sequence': entry.sequence,
  'timestamp': {
    'physicalMs': entry.timestamp.physicalMs,
    'logical': entry.timestamp.logical,
  },
};

/// Per-version SEND-side strategy: owns frame framing and the only payload
/// schema that differs between versions ([DeltaResponse] and its entry
/// encoding). Decode stays on the facade's single tolerant decoder, which
/// must accept both versions' additive shapes regardless of which version
/// this node emits.
abstract interface class SyncWireEmission {
  Uint8List frame(int messageType, List<int> jsonBytes);
  Map<String, dynamic> deltaResponseJson(DeltaResponse message);

  /// Encoded size of one entry inside this version's `entries` array —
  /// budgeting must track the active send codec, not a fixed formula.
  int encodedEntrySize(LogEntry entry);
}

/// Legacy unprefixed emission: `[type][JSON]`, int-array payloads, no
/// `hasMore` (continuation degrades to later gossip rounds), additive
/// `floor`.
class SyncEmissionV1 implements SyncWireEmission {
  const SyncEmissionV1();

  @override
  Uint8List frame(int messageType, List<int> jsonBytes) {
    final result = Uint8List(1 + jsonBytes.length);
    result[0] = messageType;
    result.setRange(1, result.length, jsonBytes);
    return result;
  }

  @override
  Map<String, dynamic> deltaResponseJson(DeltaResponse message) => {
    'sender': message.sender.value,
    'channelId': message.channelId.value,
    'streamId': message.streamId.value,
    'entries': [for (final e in message.entries) _entryJson(e)],
    // Omitted when empty (the common case) to save wire bytes; legacy
    // decoders ignore unknown keys.
    if (message.floor.entries.isNotEmpty)
      'floor': versionVectorJson(message.floor),
  };

  Map<String, dynamic> _entryJson(LogEntry entry) => {
    ...entryEnvelopeJson(entry),
    'payload': entry.payload.toList(),
  };

  @override
  int encodedEntrySize(LogEntry entry) =>
      utf8.encode(jsonEncode(_entryJson(entry))).length;
}

/// Prefixed emission: `[0xF2][type][JSON]`, base64 payloads, `hasMore`
/// always present, `floor` when non-empty.
class SyncEmissionV2 implements SyncWireEmission {
  const SyncEmissionV2();

  @override
  Uint8List frame(int messageType, List<int> jsonBytes) {
    final result = Uint8List(2 + jsonBytes.length);
    result[0] = WireTypes.markerV2;
    result[1] = messageType;
    result.setRange(2, result.length, jsonBytes);
    return result;
  }

  @override
  Map<String, dynamic> deltaResponseJson(DeltaResponse message) => {
    'sender': message.sender.value,
    'channelId': message.channelId.value,
    'streamId': message.streamId.value,
    'entries': [for (final e in message.entries) _entryJson(e)],
    'hasMore': message.hasMore,
    if (message.floor.entries.isNotEmpty)
      'floor': versionVectorJson(message.floor),
  };

  Map<String, dynamic> _entryJson(LogEntry entry) => {
    ...entryEnvelopeJson(entry),
    // base64 (~1.33 chars/byte) instead of a JSON int list (~3.6
    // chars/byte): payload size dominates DeltaResponse size, which must
    // fit the transport size limit.
    'payload': base64Encode(entry.payload),
  };

  @override
  int encodedEntrySize(LogEntry entry) =>
      utf8.encode(jsonEncode(_entryJson(entry))).length;
}
