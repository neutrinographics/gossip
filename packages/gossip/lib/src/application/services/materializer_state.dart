import 'dart:async';

import 'package:gossip/src/domain/interfaces/state_materializer.dart';
import 'package:gossip/src/application/services/fold_cursor.dart';

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

  /// Chain serializing all fold-engine operations (initialize, fold,
  /// rebuild) for this materializer. Operations have awaits between
  /// reading and publishing state; running them concurrently lets a
  /// slow initialization clobber a fold that completed meanwhile.
  Future<void> opChain = Future<void>.value();

  final StreamController<T> _stateController = StreamController<T>.broadcast();

  MaterializerState(this.materializer);

  Stream<T> get stateStream => _stateController.stream;

  void emit(T state) {
    cachedState = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  Future<void> dispose() async {
    await _stateController.close();
  }
}
