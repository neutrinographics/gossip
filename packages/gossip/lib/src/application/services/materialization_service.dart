import '../../domain/interfaces/entry_repository.dart';
import '../../domain/interfaces/state_materializer.dart';
import '../../domain/value_objects/channel_id.dart';
import '../../domain/value_objects/log_entry.dart';
import '../../domain/value_objects/stream_id.dart';
import 'fold_cursor.dart';
import 'materializer_state.dart';

/// Application service managing materialized state for event streams.
///
/// Owns the fold engine: registration, initialization, incremental folding,
/// out-of-order rebuild, and state streaming. Only accessed by [ChannelService].
///
/// Materializer state is held in-memory and is NOT persisted. Applications
/// must re-register materializers after restart. Cached state and cursors
/// are persisted via the [StateMaterializer.save] callback.
class MaterializationService {
  final EntryRepository _entryRepository;

  final Map<(ChannelId, StreamId, Type), MaterializerState<dynamic>> _states =
      {};

  MaterializationService({required EntryRepository entryRepository})
    : _entryRepository = entryRepository;

  /// Registers a materializer for a (channel, stream, type) triple.
  ///
  /// Multiple materializers with different state types can coexist on the
  /// same stream. Registering a materializer with the same state type
  /// replaces (and disposes) the previous one — awaited, so its stream
  /// listeners get onDone and a dispose failure surfaces to the caller.
  Future<void> register<T>(
    ChannelId channelId,
    StreamId streamId,
    StateMaterializer<T> materializer,
  ) async {
    final key = (channelId, streamId, T);
    // Insert synchronously (callers may not await), then dispose the
    // replaced state — awaited so its listeners get onDone and a dispose
    // failure surfaces here rather than as an unhandled async error.
    final previous = _states[key];
    _states[key] = MaterializerState<T>(materializer);
    await previous?.dispose();
  }

  /// Returns the materialized state, initializing on first call.
  ///
  /// Returns null if no materializer of type [T] is registered.
  Future<T?> getState<T>(ChannelId channelId, StreamId streamId) async {
    final matState = _states[(channelId, streamId, T)];
    if (matState == null) return null;
    final typed = matState as MaterializerState<T>;

    if (!typed.isInitialized) {
      await _enqueue(typed, () async {
        // Re-check inside the chain: a queued-ahead operation may have
        // initialized already.
        if (!typed.isInitialized) {
          await _initialize<T>(typed, channelId, streamId);
        }
      });
    }

    return typed.cachedState;
  }

  /// Runs [op] serialized behind all previous operations for [matState].
  ///
  /// A failed predecessor doesn't block the chain; its error surfaces to
  /// its own awaiter.
  Future<void> _enqueue(
    MaterializerState<dynamic> matState,
    Future<void> Function() op,
  ) {
    final task = matState.opChain.catchError((_) {}).then((_) => op());
    matState.opChain = task;
    return task;
  }

  /// Returns the broadcast stream of state updates.
  ///
  /// Returns null if no materializer of type [T] is registered.
  Stream<T>? getStateStream<T>(ChannelId channelId, StreamId streamId) {
    final matState = _states[(channelId, streamId, T)];
    if (matState == null) return null;
    return (matState as MaterializerState<T>).stateStream;
  }

  /// Folds new entries into all materializers registered for the stream.
  ///
  /// If [containsOutOfOrderEntries] is true, performs a full rebuild.
  /// Otherwise performs an incremental fold of only the new entries.
  Future<void> foldEntries(
    ChannelId channelId,
    StreamId streamId,
    List<LogEntry> entries, {
    bool containsOutOfOrderEntries = false,
  }) async {
    // Enqueue for ALL materializers before awaiting any: awaiting
    // sequentially lets one throwing materializer starve its siblings of
    // the batch — their cursors then jump over it on the next successful
    // fold, a silent permanent divergence. Future.wait (non-eager) lets
    // every fold finish and still surfaces the first failure.
    final tasks = [
      for (final matState in _statesForStream(channelId, streamId).toList())
        _enqueue(
          matState,
          () => _foldForState(
            matState,
            channelId,
            streamId,
            entries,
            containsOutOfOrderEntries: containsOutOfOrderEntries,
          ),
        ),
    ];
    await Future.wait(tasks);
  }

  /// Forces a full rebuild of all materializers for the stream.
  Future<void> reset(ChannelId channelId, StreamId streamId) async {
    final tasks = [
      for (final matState in _statesForStream(channelId, streamId).toList())
        _enqueue(matState, () => _fullRebuild(matState, channelId, streamId)),
    ];
    await Future.wait(tasks);
  }

  /// Disposes all materializer state for a channel.
  Future<void> disposeChannel(ChannelId channelId) async {
    final keysToRemove = _states.keys
        .where((key) => key.$1 == channelId)
        .toList();
    for (final key in keysToRemove) {
      await _states[key]?.dispose();
      _states.remove(key);
    }
  }

  /// Disposes all materializer state.
  Future<void> disposeAll() async {
    // Snapshot: a register() landing between the awaits would otherwise
    // mutate the map mid-iteration.
    final states = _states.values.toList();
    _states.clear();
    for (final state in states) {
      await state.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Returns all materializer states registered for a (channel, stream) pair.
  Iterable<MaterializerState<dynamic>> _statesForStream(
    ChannelId channelId,
    StreamId streamId,
  ) {
    return _states.entries
        .where((e) => e.key.$1 == channelId && e.key.$2 == streamId)
        .map((e) => e.value);
  }

  // ---------------------------------------------------------------------------
  // Fold engine
  // ---------------------------------------------------------------------------

  /// Type-safe dispatch: initializes if needed, then rebuilds or folds.
  Future<void> _foldForState<T>(
    MaterializerState<T> matState,
    ChannelId channelId,
    StreamId streamId,
    List<LogEntry> newEntries, {
    bool containsOutOfOrderEntries = false,
  }) async {
    if (!matState.isInitialized) {
      // Operations are serialized per materializer and entries are stored
      // before foldEntries is called, so initialization's getAll() is
      // guaranteed to include [newEntries] — no separate fold needed.
      await _initialize<T>(matState, channelId, streamId);
      return;
    }

    if (containsOutOfOrderEntries) {
      await _fullRebuild<T>(matState, channelId, streamId);
    } else {
      _incrementalFold<T>(matState, newEntries);
      if (matState.cursor != null) {
        await matState.materializer.save(
          matState.cachedState as T,
          matState.cursor!.toString(),
        );
      }
      matState.emit(matState.cachedState as T);
    }
  }

  /// Initializes a materializer on first use.
  ///
  /// Calls `initial(isReset: false)` to load cached state + cursor.
  /// If cursor is valid, folds only entries after the cursor.
  /// If cursor is invalid, falls back to full rebuild.
  Future<void> _initialize<T>(
    MaterializerState<T> matState,
    ChannelId channelId,
    StreamId streamId,
  ) async {
    final (state, cursorStr) = await matState.materializer.initial(
      isReset: false,
    );

    FoldCursor? cursor;
    if (cursorStr != null) {
      cursor = FoldCursor.tryParse(cursorStr);
      if (cursor == null) {
        // Invalid cursor — force full rebuild
        await _fullRebuild<T>(matState, channelId, streamId);
        return;
      }
    }

    // Fold entries beyond the cursor (full entry order, not timestamp
    // alone — an entry TYING the cursor's timestamp may still be unfolded).
    final allEntries = await _entryRepository.getAll(channelId, streamId);
    final c = cursor; // promote to non-nullable
    final entriesToFold = c == null
        ? allEntries
        : allEntries.where(c.isBefore).toList();

    T currentState = state;
    for (final entry in entriesToFold) {
      currentState = matState.materializer.fold(currentState, entry);
    }

    final newCursor = allEntries.isNotEmpty
        ? FoldCursor.fromEntry(allEntries.last)
        : cursor;

    if (newCursor != null) {
      await matState.materializer.save(currentState, newCursor.toString());
    }

    // Publish only after the save so a failed save leaves the state
    // unpublished (the next operation retries initialization).
    matState.cursor = newCursor;
    matState.cachedState = currentState;
    matState.isInitialized = true;
    matState.emit(currentState);
  }

  /// Full rebuild: calls `initial(isReset: true)` and re-folds all entries.
  Future<void> _fullRebuild<T>(
    MaterializerState<T> matState,
    ChannelId channelId,
    StreamId streamId,
  ) async {
    final (resetState, _) = await matState.materializer.initial(isReset: true);
    final allEntries = await _entryRepository.getAll(channelId, streamId);

    T state = resetState;
    for (final entry in allEntries) {
      state = matState.materializer.fold(state, entry);
    }

    matState.cursor = allEntries.isNotEmpty
        ? FoldCursor.fromEntry(allEntries.last)
        : null;
    matState.cachedState = state;
    matState.isInitialized = true;

    if (matState.cursor != null) {
      await matState.materializer.save(state, matState.cursor!.toString());
    }

    matState.emit(state);
  }

  /// Incremental fold: applies only new entries to cached state.
  void _incrementalFold<T>(
    MaterializerState<T> matState,
    List<LogEntry> newEntries,
  ) {
    T state = matState.cachedState as T;
    for (final entry in newEntries) {
      state = matState.materializer.fold(state, entry);
    }
    if (newEntries.isNotEmpty) {
      matState.cursor = FoldCursor.fromEntry(newEntries.last);
    }
    matState.cachedState = state;
  }
}
