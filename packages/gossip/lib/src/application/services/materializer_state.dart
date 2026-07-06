import 'dart:async';

import '../../domain/interfaces/state_materializer.dart';
import '../../domain/value_objects/hlc.dart';

/// Internal tracking state for a registered materializer.
///
/// Holds the cached materialized value, the cursor (last-folded HLC),
/// the materializer instance, and a broadcast StreamController for
/// state change notifications.
///
/// This class is internal to the gossip library and is not exported.
class MaterializerState<T> {
  final StateMaterializer<T> materializer;
  T? cachedState;
  Hlc? cursor;
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
