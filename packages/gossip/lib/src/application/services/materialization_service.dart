import '../../domain/interfaces/entry_repository.dart';
import '../../domain/interfaces/state_materializer.dart';
import '../../domain/value_objects/channel_id.dart';
import '../../domain/value_objects/hlc.dart';
import '../../domain/value_objects/log_entry.dart';
import '../../domain/value_objects/stream_id.dart';
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

  final Map<(ChannelId, StreamId), MaterializerState<dynamic>> _states = {};

  MaterializationService({required EntryRepository entryRepository})
    : _entryRepository = entryRepository;

  /// Registers a materializer for a (channel, stream) pair.
  ///
  /// Disposes any previously registered materializer for the same pair.
  void register<T>(
    ChannelId channelId,
    StreamId streamId,
    StateMaterializer<T> materializer,
  ) {
    final key = (channelId, streamId);
    _states[key]?.dispose();
    _states[key] = MaterializerState<T>(materializer);
  }

  /// Returns the materialized state, initializing on first call.
  ///
  /// Returns null if no materializer is registered.
  /// Throws [TypeError] if [T] doesn't match the registered materializer.
  Future<T?> getState<T>(ChannelId channelId, StreamId streamId) async {
    final matState = _states[(channelId, streamId)];
    if (matState == null) return null;
    if (matState is! MaterializerState<T>) throw TypeError();

    if (!matState.isInitialized) {
      await _initialize<T>(matState, channelId, streamId);
    }

    return matState.cachedState;
  }

  /// Returns the broadcast stream of state updates.
  ///
  /// Returns null if no materializer is registered.
  Stream<T>? getStateStream<T>(ChannelId channelId, StreamId streamId) {
    final matState = _states[(channelId, streamId)];
    if (matState == null) return null;
    if (matState is! MaterializerState<T>) return null;
    return matState.stateStream;
  }

  /// Folds new entries into the materialized state.
  ///
  /// If [containsOutOfOrderEntries] is true, performs a full rebuild.
  /// Otherwise performs an incremental fold of only the new entries.
  Future<void> foldEntries(
    ChannelId channelId,
    StreamId streamId,
    List<LogEntry> entries, {
    bool containsOutOfOrderEntries = false,
  }) async {
    final matState = _states[(channelId, streamId)];
    if (matState == null) return;
    await _foldForState(
      matState,
      channelId,
      streamId,
      entries,
      containsOutOfOrderEntries: containsOutOfOrderEntries,
    );
  }

  /// Forces a full rebuild of the materialized state.
  Future<void> reset(ChannelId channelId, StreamId streamId) async {
    final matState = _states[(channelId, streamId)];
    if (matState == null) return;
    await _fullRebuild(matState, channelId, streamId);
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
    for (final state in _states.values) {
      await state.dispose();
    }
    _states.clear();
  }

  // ---------------------------------------------------------------------------
  // Private fold engine
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

    Hlc? cursor;
    if (cursorStr != null) {
      cursor = Hlc.tryParse(cursorStr);
      if (cursor == null) {
        // Invalid cursor — force full rebuild
        await _fullRebuild<T>(matState, channelId, streamId);
        return;
      }
    }

    matState.cachedState = state;
    matState.cursor = cursor;

    // Fold entries beyond the cursor
    final allEntries = await _entryRepository.getAll(channelId, streamId);
    final c = cursor; // promote to non-nullable
    final entriesToFold = c == null
        ? allEntries
        : allEntries.where((e) => e.timestamp > c).toList();

    T currentState = matState.cachedState as T;
    for (final entry in entriesToFold) {
      currentState = matState.materializer.fold(currentState, entry);
    }

    // Update cursor to tail
    if (allEntries.isNotEmpty) {
      matState.cursor = allEntries.last.timestamp;
    }
    matState.cachedState = currentState;
    matState.isInitialized = true;

    if (matState.cursor != null) {
      await matState.materializer.save(
        currentState,
        matState.cursor!.toString(),
      );
    }

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

    matState.cursor = allEntries.isNotEmpty ? allEntries.last.timestamp : null;
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
      matState.cursor = newEntries.last.timestamp;
    }
    matState.cachedState = state;
  }
}
