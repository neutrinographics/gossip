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
/// // Pre-set in a local node repository
/// final repo = InMemoryLocalNodeRepository(nodeId: NodeId('my-device'));
///
/// // Add as peer
/// await coordinator.addPeer(NodeId('other-device'));
/// ```
///
/// ## Choosing Node IDs
///
/// Node IDs should be:
/// - **Globally unique**: UUIDs work well
/// - **Persisted**: The [LocalNodeRepository] handles persistence; generate
///   once and reuse across restarts
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
  NodeId(this.value) {
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
