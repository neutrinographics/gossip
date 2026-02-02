import 'dart:typed_data';

import '../application/services/channel_service.dart';
import '../domain/interfaces/state_materializer.dart';
import '../domain/value_objects/channel_id.dart';
import '../domain/value_objects/stream_id.dart';

/// Public API for stream-level read/write operations.
///
/// An [EventStream] is an append-only log of entries within a channel.
/// Entries are synchronized across peers via the gossip protocol and
/// ordered using Hybrid Logical Clocks (HLC) for deterministic causality.
///
/// ## Writing Entries
///
/// Append opaque byte payloads to the stream:
///
/// ```dart
/// final stream = await channel.getOrCreateStream(StreamId('messages'));
///
/// // Append raw bytes
/// await stream.append(Uint8List.fromList([1, 2, 3]));
///
/// // Append serialized data (application defines format)
/// final json = utf8.encode('{"message": "hello"}');
/// await stream.append(Uint8List.fromList(json));
/// ```
///
/// ## Reading Entries
///
/// Retrieve all entries in causal order:
///
/// ```dart
/// final entries = await stream.getAll();
/// for (final entry in entries) {
///   print('Author: ${entry.author}, Payload: ${entry.payload}');
/// }
/// ```
///
/// ## State Materialization
///
/// For event-sourced patterns, register a materializer to compute
/// derived state from the entry log:
///
/// ```dart
/// // Define a materializer (counter example)
/// class CounterMaterializer implements StateMaterializer<int> {
///   @override
///   int initial() => 0;
///
///   @override
///   int fold(int state, LogEntry entry) => state + 1;
/// }
///
/// // Register and use
/// await stream.registerMaterializer(CounterMaterializer());
/// final count = await stream.getState<int>();
/// print('Entry count: $count');
/// ```
///
/// ## Entry Ordering
///
/// Entries are ordered by HLC timestamp, which combines:
/// - Physical wall clock time (milliseconds)
/// - Logical counter for events at the same millisecond
/// - Author ID as tiebreaker for deterministic ordering
///
/// This ensures all peers see the same order after sync converges.
///
/// ## Payload Size Limit
///
/// Payloads must not exceed 32KB to maintain compatibility with
/// transport layers like Android Nearby Connections. Larger payloads
/// should be chunked at the application level.
///
/// See also:
/// - [Channel] for stream creation
/// - [StateMaterializer] for state computation
/// - [LogEntry] for entry structure
class EventStream {
  /// The stream identifier.
  final StreamId id;

  /// The channel this stream belongs to.
  final ChannelId channelId;

  /// The channel service for persistence operations.
  final ChannelService channelService;

  /// Creates an event stream.
  const EventStream({
    required this.id,
    required this.channelId,
    required this.channelService,
  });

  /// Appends a new entry to the stream.
  ///
  /// Creates a [LogEntry] with the given payload, authored by the local node.
  /// The entry is assigned the next sequence number and current timestamp.
  ///
  /// Used when: Application writes new data to the stream.
  Future<void> append(Uint8List payload) async {
    await channelService.appendEntry(channelId, id, payload);
  }

  /// Returns all entries in the stream, ordered by HLC timestamp.
  ///
  /// Entries are returned in deterministic causal order.
  ///
  /// Used when: Application reads all stream data.
  Future<List<dynamic>> getAll() async {
    return await channelService.getEntries(channelId, id);
  }

  /// Registers a materializer for computing derived state from entries.
  ///
  /// The materializer will be called to fold entries into state when
  /// [getState] is called. Materializers must be re-registered after
  /// restarting the application as they are not persisted.
  ///
  /// Example:
  /// ```dart
  /// final stream = channel.getStream(streamId);
  /// stream.registerMaterializer(CounterMaterializer());
  /// final count = await stream.getState<int>();
  /// ```
  Future<void> registerMaterializer<T>(
    StateMaterializer<T> materializer,
  ) async {
    await channelService.registerMaterializer(channelId, id, materializer);
  }

  /// Returns the materialized state for this stream.
  ///
  /// Applies the registered materializer to all entries in the stream,
  /// folding them in timestamp order to produce the final state.
  ///
  /// Returns null if no materializer is registered or if the stream doesn't exist.
  ///
  /// Example:
  /// ```dart
  /// final stream = channel.getStream(streamId);
  /// final currentState = await stream.getState<MyState>();
  /// ```
  Future<T?> getState<T>() async {
    return await channelService.getState<T>(channelId, id);
  }
}
