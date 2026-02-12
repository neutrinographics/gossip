import '../value_objects/channel_id.dart';
import '../value_objects/log_entry.dart';
import '../value_objects/node_id.dart';
import '../value_objects/stream_id.dart';

/// Base class for recoverable synchronization errors.
///
/// [SyncError] represents expected failures during gossip synchronization
/// that can occur in distributed systems:
/// - Network failures (timeouts, unreachable peers)
/// - Protocol violations (corrupted messages, version mismatches)
/// - Storage issues (disk full, write failures)
/// - Buffer overflows (rate limiting, out-of-order entries)
///
/// Unlike [DomainException], these errors are expected and recoverable.
/// Applications should observe [SyncErrorOccurred] events to log errors,
/// implement retry policies, or alert operators.
sealed class SyncError {
  /// Human-readable description of the error.
  final String message;

  /// When the error occurred.
  final DateTime occurredAt;

  const SyncError(this.message, {required this.occurredAt});
}

/// Error during peer-to-peer communication.
///
/// Represents failures when sending or receiving messages from a specific peer.
/// Common causes: network timeouts, connection failures, unreachable peers.
final class PeerSyncError extends SyncError {
  /// The peer involved in the failed communication.
  final NodeId peer;

  /// Classification of the error type.
  final SyncErrorType type;

  /// Original exception or error that caused this failure (if available).
  final Object? cause;

  const PeerSyncError(
    this.peer,
    this.type,
    super.message, {
    required super.occurredAt,
    this.cause,
  });
}

/// Error during channel synchronization.
///
/// Represents failures specific to a channel, such as protocol violations,
/// access control issues, or channel-level configuration problems.
final class ChannelSyncError extends SyncError {
  /// The channel where the error occurred.
  final ChannelId channel;

  /// Classification of the error type.
  final SyncErrorType type;

  /// Original exception or error that caused this failure (if available).
  final Object? cause;

  const ChannelSyncError(
    this.channel,
    this.type,
    super.message, {
    required super.occurredAt,
    this.cause,
  });
}

/// Error during storage operations.
///
/// Represents failures when reading from or writing to persistent storage.
/// Common causes: disk full, I/O errors, serialization failures.
final class StorageSyncError extends SyncError {
  /// Classification of the error type.
  final SyncErrorType type;

  /// Original exception or error that caused this failure (if available).
  final Object? cause;

  const StorageSyncError(
    this.type,
    super.message, {
    required super.occurredAt,
    this.cause,
  });
}

/// Error during payload transformation.
///
/// Represents failures when encoding or decoding application payloads.
/// The library treats payloads as opaque bytes, but applications may
/// encounter serialization errors.
final class TransformSyncError extends SyncError {
  /// The channel being transformed (if applicable).
  final ChannelId? channel;

  /// Original exception or error that caused this failure (if available).
  final Object? cause;

  const TransformSyncError(
    super.message, {
    required super.occurredAt,
    this.channel,
    this.cause,
  });
}

/// Error when out-of-order buffer capacity is exceeded.
///
/// Represents buffer overflow when receiving out-of-order entries.
/// Triggers when [StreamConfig] limits are exceeded to prevent memory
/// exhaustion from malicious or buggy peers.
final class BufferOverflowError extends SyncError {
  /// The channel containing the overflowing stream.
  final ChannelId channel;

  /// The stream with the buffer overflow.
  final StreamId stream;

  /// The author whose entries caused the overflow.
  final NodeId author;

  /// Current size of the buffer when overflow occurred.
  final int bufferSize;

  const BufferOverflowError(
    this.channel,
    this.stream,
    this.author,
    this.bufferSize,
    super.message, {
    required super.occurredAt,
  });
}

/// Categories of synchronization errors.
///
/// Classifies the root cause of sync failures to enable appropriate
/// handling and recovery strategies.
enum SyncErrorType {
  /// Peer is not reachable via network.
  peerUnreachable,

  /// Communication with peer timed out.
  peerTimeout,

  /// Received message failed validation or decoding.
  messageCorrupted,

  /// Message size exceeds protocol limits (32KB).
  messageTooLarge,

  /// Protocol version mismatch between peers.
  versionMismatch,

  /// Storage operation failed (read/write error).
  storageFailure,

  /// Storage capacity exhausted (disk full).
  storageFull,

  /// Payload serialization/deserialization failed.
  transformFailure,

  /// Protocol rule violation.
  protocolError,

  /// Out-of-order buffer capacity exceeded.
  bufferOverflow,

  /// Entry author is not a channel member.
  notAMember,
}

/// Callback type for receiving synchronization errors.
///
/// Used by protocol and service classes to report errors to observers.
/// Applications typically wire this up to emit [SyncErrorOccurred] events
/// or log errors for observability.
typedef ErrorCallback = void Function(SyncError error);

/// Callback signature for when entries are merged from a peer.
///
/// Used by [GossipEngine] to notify when entries are received and stored
/// during anti-entropy synchronization. Applications wire this up to emit
/// [EntriesMerged] events for UI updates.
typedef EntriesMergedCallback =
    Future<void> Function(
      ChannelId channelId,
      StreamId streamId,
      List<LogEntry> entries,
    );
