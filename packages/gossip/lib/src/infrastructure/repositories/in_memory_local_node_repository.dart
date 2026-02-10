import '../../domain/value_objects/hlc.dart';
import '../../domain/interfaces/local_node_repository.dart';

/// In-memory implementation of [LocalNodeRepository] for testing.
///
/// This implementation stores local node state in simple fields with no
/// persistence. All data is lost when the application terminates.
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
  Hlc _clockState = Hlc.zero;
  int _incarnation = 0;

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
