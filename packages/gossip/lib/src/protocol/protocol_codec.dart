import 'dart:typed_data';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/interfaces/protocol_message.dart';
import 'package:gossip/src/membership/domain/messages/ping.dart';
import 'package:gossip/src/membership/domain/messages/ack.dart';
import 'package:gossip/src/membership/domain/messages/ping_req.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';
import 'package:gossip/src/protocol/messages/delta_request.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:gossip/src/protocol/values/stream_digest.dart';
import 'package:gossip/src/membership/infrastructure/membership_message_codec.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';

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
///
/// ## Bounded-contexts note
/// This class is now a thin composite over [MembershipMessageCodec] (types
/// 0-2) and [SyncMessageCodec] (types 3-6) — see the bounded-contexts
/// restructure plan. It exists only so the gossip engine and SWIM failure
/// detector can keep using a single codec until Task 3 moves them onto the
/// per-context `MessageCodec` interface directly; Task 7 deletes this class
/// once nothing depends on it. Its public behavior — including error
/// messages for unknown/malformed frames — is unchanged from before the
/// split; that is the regression proof.
class ProtocolCodec {
  final MembershipMessageCodec _membershipCodec = MembershipMessageCodec();
  final SyncMessageCodec _syncCodec = SyncMessageCodec();

  /// Encodes a protocol message to bytes for wire transmission.
  ///
  /// Returns a byte array where:
  /// - Byte 0: Message type identifier
  /// - Remaining bytes: UTF-8 JSON-encoded message fields
  ///
  /// Throws [ArgumentError] if the message type is unknown.
  Uint8List encode(ProtocolMessage message) {
    if (message is Ping || message is Ack || message is PingReq) {
      return _membershipCodec.encode(message);
    }
    if (message is DigestRequest ||
        message is DigestResponse ||
        message is DeltaRequest ||
        message is DeltaResponse) {
      return _syncCodec.encode(message);
    }
    throw ArgumentError('Unknown message type: ${message.runtimeType}');
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
    // Try membership first; if bytes is empty, this throws the same
    // ArgumentError the pre-split codec did, before either codec would
    // otherwise get a chance to inspect the (nonexistent) type byte.
    final membershipResult = _membershipCodec.decode(bytes);
    if (membershipResult != null) return membershipResult;

    final syncResult = _syncCodec.decode(bytes);
    if (syncResult != null) return syncResult;

    // Both context codecs answered "not mine" — the type byte is outside
    // 0-6. Mirror the exact error the single codec used to raise.
    final messageType = bytes[0];
    throw ArgumentError('Unknown message type: $messageType');
  }

  /// Returns the encoded size in bytes of a single log entry as it would
  /// appear inside a message's `entries` array.
  ///
  /// Used by the gossip engine to budget [DeltaResponse] messages against
  /// the transport size limit without repeatedly encoding whole messages.
  int encodedEntrySize(LogEntry entry) => _syncCodec.encodedEntrySize(entry);

  /// Returns the encoded JSON size in bytes of a single [StreamDigest] as it
  /// appears inside a digest message's `streams` array.
  ///
  /// Used by the gossip engine to budget DigestRequest/DigestResponse
  /// messages against the transport limit without repeatedly encoding whole
  /// messages.
  int encodedStreamDigestSize(StreamDigest digest) =>
      _syncCodec.encodedStreamDigestSize(digest);

  /// Largest entry payload (raw bytes) guaranteed to fit a [DeltaResponse]
  /// whose encoded size may not exceed [budgetBytes].
  ///
  /// Delegates to [SyncMessageCodec.maxEntryPayloadForBudget] — entries are
  /// a sync concern. Kept here so existing call sites (tests, and any code
  /// not yet migrated to [SyncMessageCodec] directly) are unaffected.
  static int maxEntryPayloadForBudget(int budgetBytes) =>
      SyncMessageCodec.maxEntryPayloadForBudget(budgetBytes);
}
