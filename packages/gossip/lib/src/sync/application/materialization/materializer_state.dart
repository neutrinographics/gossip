import 'dart:async';

import 'package:gossip/src/sync/domain/interfaces/state_materializer.dart';
import 'package:gossip/src/sync/application/materialization/fold_cursor.dart';

/// Internal tracking state for a registered materializer.
///
/// Holds the cached materialized value, the cursor (position of the last
/// folded entry), the materializer instance, and a broadcast
/// StreamController for state change notifications.
///
/// This class is internal to the gossip library and is not exported.
class MaterializerState<T> {
  final StateMaterializer<T> materializer;
  T? cachedState;
  FoldCursor? cursor;
  bool isInitialized = false;

  final StreamController<T> _stateController = StreamController<T>.broadcast();

  MaterializerState(this.materializer);

  Stream<T> get stateStream => _stateController.stream;

  /// Notifies listeners; state mutation is `_commit`'s job.
  void emit(T state) {
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  Future<void> dispose() async {
    await _stateController.close();
  }
}
