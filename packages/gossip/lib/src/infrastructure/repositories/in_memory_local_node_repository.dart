import 'package:uuid/uuid.dart';

import '../../domain/value_objects/hlc.dart';
import '../../domain/value_objects/node_id.dart';
import '../../domain/interfaces/local_node_repository.dart';

/// In-memory implementation of [LocalNodeRepository] for testing.
///
/// This implementation stores local node state in simple fields with no
/// persistence. All data is lost when the application terminates.
///
/// An optional [nodeId] can be provided to the constructor for tests that
/// need a known, deterministic node ID. If not provided, [generateNodeId]
/// creates a random UUID.
///
/// **Use only for testing and prototyping.**
///
/// For production applications, implement [LocalNodeRepository] with
/// persistent storage:
/// - SharedPreferences or key-value store for simple cases
/// - A single-row table in SQLite for relational storage
///
/// All operations complete synchronously but return [Future] to match the
/// repository interface contract.
class InMemoryLocalNodeRepository implements LocalNodeRepository {
  NodeId? _nodeId;
  Hlc _clockState = Hlc.zero;
  int _incarnation = 0;

  /// Creates an in-memory local node repository.
  ///
  /// If [nodeId] is provided, [getNodeId] returns it immediately without
  /// needing [generateNodeId]. This is useful for tests that need to
  /// reference the node ID before creating the coordinator.
  InMemoryLocalNodeRepository({NodeId? nodeId}) : _nodeId = nodeId;

  @override
  Future<NodeId?> getNodeId() async => _nodeId;

  @override
  Future<void> saveNodeId(NodeId nodeId) async {
    _nodeId = nodeId;
  }

  @override
  Future<NodeId> generateNodeId() async => NodeId(const Uuid().v4());

  @override
  Future<Hlc> getClockState() async => _clockState;

  @override
  Future<void> saveClockState(Hlc state) async {
    _clockState = state;
  }

  @override
  Future<int> getIncarnation() async => _incarnation;

  @override
  Future<void> saveIncarnation(int incarnation) async {
    _incarnation = incarnation;
  }
}
