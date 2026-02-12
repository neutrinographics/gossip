import '../value_objects/hlc.dart';
import '../value_objects/node_id.dart';

/// Repository for persisting local node state across application restarts.
///
/// [LocalNodeRepository] is the single source of truth for local node
/// identity and state. It stores:
///
/// - **Node ID**: The local node's unique identity. On first run,
///   [generateNodeId] is called to let the consumer provide their chosen ID
///   (UUID, device ID, user-scoped ID, etc.). On subsequent runs, the
///   persisted value is loaded via [getNodeId].
///
/// - **HLC clock state**: The hybrid logical clock's last known timestamp.
///   Restoring this on startup preserves timestamp monotonicity even if the
///   system clock regresses between restarts.
///
/// - **Incarnation number**: The SWIM protocol incarnation counter. Restoring
///   this prevents peers from treating the restarted node as stale when it
///   had previously incremented its incarnation to refute false suspicions.
///
/// ## Default Values
/// When no state has been persisted, implementations should return:
/// - `null` for node ID (triggers [generateNodeId] on first run)
/// - [Hlc.zero] for clock state
/// - `0` for incarnation
///
/// ## Implementation Guidance
/// - Use key-value storage (SharedPreferences, localStorage) for simple cases
/// - Use a single-row table in SQLite for relational storage
/// - All values are small and change infrequently — no special
///   performance considerations needed
///
/// See also:
/// - [InMemoryLocalNodeRepository] for the reference implementation
/// - [ChannelRepository] for channel metadata storage
/// - [EntryRepository] for log entry storage
/// - [PeerRepository] for peer state storage
abstract interface class LocalNodeRepository {
  /// Returns the persisted node ID, or `null` if this is the first run.
  Future<NodeId?> getNodeId();

  /// Persists the local node ID.
  ///
  /// Called by [Coordinator.create] after [generateNodeId] on first run.
  /// Should not be called directly by consumers.
  Future<void> saveNodeId(NodeId nodeId);

  /// Called on first run when no node ID exists in storage.
  ///
  /// **Must return a globally unique value on every call** (e.g., a UUID).
  /// Do NOT return a deterministic value like a device MAC address or user
  /// account ID. If this node's storage is wiped and [generateNodeId] is
  /// called again, it must produce a different ID — otherwise peers will
  /// treat the returning node as having data it no longer has, causing
  /// silent entry conflicts and broken synchronization.
  ///
  /// If you need to associate a node with a stable external identity
  /// (e.g., user account), maintain that mapping separately in your
  /// application layer.
  ///
  /// The returned value will be persisted via [saveNodeId] and used for
  /// the lifetime of this node's data.
  Future<NodeId> generateNodeId();

  /// Returns the persisted HLC clock state, or [Hlc.zero] if none exists.
  Future<Hlc> getClockState();

  /// Persists the current HLC clock state.
  Future<void> saveClockState(Hlc state);

  /// Returns the persisted incarnation number, or 0 if none exists.
  Future<int> getIncarnation();

  /// Persists the current incarnation number.
  Future<void> saveIncarnation(int incarnation);
}

/// Convenience extension on [LocalNodeRepository].
extension LocalNodeRepositoryExtension on LocalNodeRepository {
  /// Resolves the local node ID, generating and persisting one if needed.
  ///
  /// On the first call (no persisted ID), this generates a new node ID via
  /// [LocalNodeRepository.generateNodeId], saves it via
  /// [LocalNodeRepository.saveNodeId], and returns it. On subsequent calls,
  /// it returns the persisted ID directly.
  Future<NodeId> resolveNodeId() async {
    var nodeId = await getNodeId();
    if (nodeId == null) {
      nodeId = await generateNodeId();
      await saveNodeId(nodeId);
    }
    return nodeId;
  }
}
