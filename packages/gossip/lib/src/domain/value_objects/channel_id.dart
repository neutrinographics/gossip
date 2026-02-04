/// Unique identifier for a channel in the gossip system.
///
/// A [ChannelId] identifies a logical grouping that contains membership
/// information and multiple streams. Channels serve as the primary boundary
/// for access control and data organization.
///
/// ## Usage
///
/// ```dart
/// // Create a channel ID
/// final channelId = ChannelId('my-project');
///
/// // Create or access a channel
/// final channel = await coordinator.createChannel(channelId);
/// final existing = coordinator.getChannel(channelId);
///
/// // Use in membership queries
/// final channels = await coordinator.channelsForPeer(peerId);
/// ```
///
/// ## Naming Conventions
///
/// Channel IDs should be:
/// - **Unique within your application**: Use project/document/group names
/// - **Human-readable**: Makes debugging easier
/// - **URL-safe**: If you plan to use them in URLs
///
/// Examples: `'project-alpha'`, `'shared-document-123'`, `'team-chat'`
///
/// Value objects are immutable and compared by value equality.
///
/// ## Invariants
/// - The identifier value must not be empty or whitespace-only
class ChannelId {
  /// The unique identifier value.
  final String value;

  /// Creates a [ChannelId] with the given unique identifier.
  ///
  /// Throws [ArgumentError] if [value] is empty or contains only whitespace.
  ChannelId(this.value) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(
        value,
        'value',
        'ChannelId cannot be empty or whitespace',
      );
    }
  }

  @override
  bool operator ==(Object other) => other is ChannelId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ChannelId($value)';
}
