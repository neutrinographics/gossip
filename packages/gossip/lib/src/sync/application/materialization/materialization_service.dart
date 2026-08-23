import 'package:gossip/src/sync/domain/interfaces/entry_repository.dart';
import 'package:gossip/src/sync/domain/interfaces/state_materializer.dart';
import 'package:gossip/src/shared/domain/services/keyed_task_chain.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/application/materialization/fold_cursor.dart';
import 'package:gossip/src/sync/application/materialization/materializer_state.dart';

/// Application service managing materialized state for event streams.
///
/// Owns the fold engine: registration, initialization, incremental folding,
/// out-of-order rebuild, and state streaming. Only accessed by `ChannelService`.
///
/// Materializer state is held in-memory and is NOT persisted. Applications
/// must re-register materializers after restart. Cached state and cursors
/// are persisted via the [StateMaterializer.save] callback.
class MaterializationService {
  final EntryRepository _entryRepository;

  final Map<(ChannelId, StreamId, Type), MaterializerState<dynamic>> _states =
      {};

  /// Chain serializing all fold-engine operations (initialize, fold,
  /// rebuild) per materializer. Operations have awaits between reading and
  /// publishing state; running them concurrently lets a slow initialization
  /// clobber a fold that completed meanwhile.
  ///
  /// Keyed by the [MaterializerState] instance itself (identity, not `==`)
  /// — it has no `==` override, which is exactly right here: each
  /// registration owns one long-lived state object, so identity is already
  /// the correct notion of "same materializer" and there's nothing a
  /// value-based `==` would add.
  final KeyedTaskChain<MaterializerState<dynamic>> _ops = KeyedTaskChain();

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
      await _ops.enqueue(typed, () async {
        // Re-check inside the chain: a queued-ahead operation may have
        // initialized already.
        if (!typed.isInitialized) {
          await _initialize<T>(typed, channelId, streamId);
        }
      });
    }

    return typed.cachedState;
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
        _ops.enqueue(
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
        _ops.enqueue(
          matState,
          () => _fullRebuild(matState, channelId, streamId),
        ),
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
      final (state, cursor) = _computeIncrementalFold<T>(matState, newEntries);
      await _commit<T>(matState, state, cursor);
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

    await _commit<T>(matState, currentState, newCursor);
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

    final cursor = allEntries.isNotEmpty
        ? FoldCursor.fromEntry(allEntries.last)
        : null;

    await _commit<T>(matState, state, cursor);
  }

  /// Computes the incremental fold result without mutating [matState] —
  /// mutation and publication are `_commit`'s job.
  (T, FoldCursor?) _computeIncrementalFold<T>(
    MaterializerState<T> matState,
    List<LogEntry> newEntries,
  ) {
    T state = matState.cachedState as T;
    for (final entry in newEntries) {
      state = matState.materializer.fold(state, entry);
    }
    final cursor = newEntries.isNotEmpty
        ? FoldCursor.fromEntry(newEntries.last)
        : matState.cursor;
    return (state, cursor);
  }

  /// Publishes a fold result: save, then mutate in-memory state, then
  /// emit. The single publish contract for every fold path (initialize,
  /// incremental fold, full rebuild).
  ///
  /// Save must happen first: mutating before a save that then fails would
  /// publish a state the persistence layer never durably recorded, so a
  /// restart (or any other reader of the persisted cursor) would diverge
  /// from what's in memory. Saving first means a failed save simply leaves
  /// [matState] at its previous state and cursor — unpublished, nothing
  /// mutated, nothing emitted.
  ///
  /// A failed save marks the materializer uninitialized rather than
  /// leaving it as-is: the caller that hits the failure typically folds
  /// only the batch that just failed, not the ones before it, so a later
  /// retry of "the next fold" would fold only NEW entries and silently
  /// skip the failed batch forever — durably losing it once that later
  /// fold's save succeeds and advances the cursor past it. Marking
  /// uninitialized routes the next operation through [_initialize], which
  /// re-reads the last committed snapshot and refolds every repository
  /// entry past the cursor — sound because the entry repository still
  /// holds the failed batch's entries, and save-first ordering guarantees
  /// persistence only ever holds committed snapshots to resume from.
  Future<void> _commit<T>(
    MaterializerState<T> matState,
    T state,
    FoldCursor? cursor,
  ) async {
    if (cursor != null) {
      try {
        await matState.materializer.save(state, cursor.toString());
      } catch (_) {
        matState.isInitialized = false;
        rethrow;
      }
    }
    matState.cursor = cursor;
    matState.cachedState = state;
    matState.isInitialized = true;
    matState.emit(state);
  }
}
