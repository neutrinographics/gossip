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

  final Map<(ChannelId, StreamId, Type), MaterializerState<dynamic>> _states =
      {};

  MaterializationService({required EntryRepository entryRepository})
    : _entryRepository = entryRepository;

  /// Registers a materializer for a (channel, stream, type) triple.
  ///
  /// Multiple materializers with different state types can coexist on the
  /// same stream. Registering a materializer with the same state type
  /// replaces (and disposes) the previous one.
  void register<T>(
    ChannelId channelId,
    StreamId streamId,
    StateMaterializer<T> materializer,
  ) {
    final key = (channelId, streamId, T);
    _states[key]?.dispose();
    _states[key] = MaterializerState<T>(materializer);
  }

  /// Returns the materialized state, initializing on first call.
  ///
  /// Returns null if no materializer of type [T] is registered.
  Future<T?> getState<T>(ChannelId channelId, StreamId streamId) async {
    final matState = _states[(channelId, streamId, T)];
    if (matState == null) return null;
    final typed = matState as MaterializerState<T>;

    if (!typed.isInitialized) {
      await _initialize<T>(typed, channelId, streamId);
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
    for (final matState in _statesForStream(channelId, streamId)) {
      await _foldForState(
        matState,
        channelId,
        streamId,
        entries,
        containsOutOfOrderEntries: containsOutOfOrderEntries,
      );
    }
  }

  /// Forces a full rebuild of all materializers for the stream.
  Future<void> reset(ChannelId channelId, StreamId streamId) async {
    for (final matState in _statesForStream(channelId, streamId)) {
      await _fullRebuild(matState, channelId, streamId);
    }
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
