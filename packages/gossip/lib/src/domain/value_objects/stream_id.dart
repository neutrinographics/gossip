/// Unique identifier for a stream within a channel.
///
/// A [StreamId] identifies an ordered log of entries within a channel.
/// Each stream has its own retention policy and sync state tracked via
/// version vectors. Streams are the granularity at which data is synced
/// between peers.
///
/// ## Usage
///
/// ```dart
/// // Create a stream ID
/// final streamId = StreamId('messages');
///
/// // Create or access a stream within a channel
/// final stream = await channel.getOrCreateStream(streamId);
///
/// // List streams in a channel
/// final streamIds = await channel.streamIds;
/// ```
///
/// ## Organizing Data into Streams
///
/// Use multiple streams to separate different types of data:
///
/// ```dart
/// // Separate streams for different purposes
/// final messages = await channel.getOrCreateStream(StreamId('messages'));
/// final metadata = await channel.getOrCreateStream(StreamId('metadata'));
/// final presence = await channel.getOrCreateStream(StreamId('presence'));
/// ```
///
/// Stream IDs are unique within a channel but can repeat across channels.
///
/// Value objects are immutable and compared by value equality.
///
/// ## Invariants
/// - The identifier value must not be empty or whitespace-only
class StreamId {
  /// The unique identifier value (unique within the channel).
  final String value;

  /// Creates a [StreamId] with the given unique identifier.
  ///
  /// Throws [ArgumentError] if [value] is empty or contains only whitespace.
  StreamId(String value) : value = value {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(
        value,
        'value',
        'StreamId cannot be empty or whitespace',
      );
    }
  }

  @override
  bool operator ==(Object other) => other is StreamId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'StreamId($value)';
}
