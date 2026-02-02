/// Globally unique identifier for a peer node in the gossip network.
///
/// A [NodeId] uniquely identifies a single peer participating in gossip.
/// Nodes use these identifiers to track peer status, send messages, and
/// maintain sync state.
///
/// ## Usage
///
/// ```dart
/// // Create from any unique string (UUID, device ID, etc.)
/// final nodeId = NodeId('device-uuid-123');
///
/// // Use as local node when creating coordinator
/// final coordinator = await Coordinator.create(
///   localNode: NodeId('my-device'),
///   // ...
/// );
///
/// // Add as peer
/// await coordinator.addPeer(NodeId('other-device'));
/// ```
///
/// ## Choosing Node IDs
///
/// Node IDs should be:
/// - **Globally unique**: UUIDs work well
/// - **Stable**: Same device should use same ID across restarts
/// - **Meaningful**: Optional - can include device name for debugging
///
/// Value objects are immutable and compared by value equality.
///
/// ## Invariants
/// - The identifier value must not be empty or whitespace-only
class NodeId {
  /// The unique identifier value (typically a UUID).
  final String value;

  /// Creates a [NodeId] with the given unique identifier.
  ///
  /// Throws [ArgumentError] if [value] is empty or contains only whitespace.
  NodeId(String value) : value = value {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(
        value,
        'value',
        'NodeId cannot be empty or whitespace',
      );
    }
  }

  @override
  bool operator ==(Object other) => other is NodeId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'NodeId($value)';
}
