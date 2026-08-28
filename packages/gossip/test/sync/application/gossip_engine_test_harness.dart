import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:gossip/src/sync/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/membership/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/shared/domain/value_objects/log_level.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/interfaces/local_node_repository.dart';
import 'package:gossip/src/sync/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/sync/domain/services/hlc_clock.dart';
import 'package:gossip/src/shared/domain/services/time_source.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/shared/domain/interfaces/message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:gossip/src/sync/application/gossip_engine.dart';
import 'package:gossip/src/sync/domain/messages/delta_request.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/infrastructure/membership_peer_directory.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';

import '../../support/pump.dart';

/// A peer node managed by the gossip engine test harness.
class GossipTestPeer {
  final NodeId id;
  final InMemoryMessagePort port;

  GossipTestPeer(this.id, this.port);
}

/// Records a single onEntriesMerged callback invocation.
class MergedEntriesRecord {
  final ChannelId channelId;
  final StreamId streamId;
  final List<LogEntry> entries;
  final bool containsOutOfOrderEntries;

  MergedEntriesRecord(
    this.channelId,
    this.streamId,
    this.entries,
    this.containsOutOfOrderEntries,
  );
}

/// Test harness encapsulating GossipEngine infrastructure.
///
/// Reduces boilerplate in gossip engine tests by managing node creation,
/// message bus wiring, channel setup, and common interaction patterns.
///
/// ```dart
/// late GossipEngineTestHarness h;
///
/// setUp(() {
///   h = GossipEngineTestHarness();
/// });
///
/// test('syncs entries', () async {
///   final peer = h.addPeer('peer1');
///   h.createChannel('ch1', streamIds: ['s1']);
///   h.startListening();
///   await h.engine.performGossipRound();
///   h.stopListening();
/// });
/// ```
class GossipEngineTestHarness {
  final NodeId localNode;
  final PeerRegistry peerRegistry;
  final InMemoryEntryRepository entryRepository;
  final InMemoryTimePort timePort;
  final InMemoryMessageBus bus;
  final InMemoryMessagePort localPort;
  final GossipEngine engine;
  final SyncMessageCodec codec;
  final HlcClock? hlcClock;
  final List<SyncError> errors;
  final List<MergedEntriesRecord> mergedEntries;

  final Map<ChannelId, ChannelAggregate> _channels = {};
  final List<GossipTestPeer> _peers = [];

  GossipEngineTestHarness._({
    required this.localNode,
    required this.peerRegistry,
    required this.entryRepository,
    required this.timePort,
    required this.bus,
    required this.localPort,
    required this.engine,
    required this.codec,
    required this.hlcClock,
    required this.errors,
    required this.mergedEntries,
  });

  /// Creates a harness with the given configuration.
  ///
  /// [onEntriesMerged] overrides the default callback (which just records
  /// into [mergedEntries]) — tests that need a handler-side failure inject
  /// a throwing callback here, since it's a real constructor-provided
  /// collaborator reached through the actual incoming-message dispatch,
  /// not a mock of any engine internal.
  factory GossipEngineTestHarness({
    String localName = 'local',
    Duration? gossipInterval,
    bool adaptiveTimingEnabled = false,
    bool withHlcClock = false,
    MessagePort? messagePort,
    int? maxMessageBytes,
    Random? random,
    EntriesMergedCallback? onEntriesMerged,
    // Defaulting to v2 preserves what the existing suite pins; a later task wires
    // this to the real coordinator config default (v1).
    WireVersion wireVersion = WireVersion.v2,
  }) {
    final localNode = NodeId(localName);
    final peerRegistry = PeerRegistry(localNode: localNode);
    final timePort = InMemoryTimePort();
    final bus = InMemoryMessageBus();
    final localPort = InMemoryMessagePort(localNode, bus);
    final entryRepository = InMemoryEntryRepository();
    final errors = <SyncError>[];
    final mergedEntries = <MergedEntriesRecord>[];
    final codec = SyncMessageCodec(wireVersion: wireVersion);

    HlcClock? hlcClock;
    if (withHlcClock) {
      hlcClock = HlcClock(TimeSource(timePort));
    }

    final engine = GossipEngine(
      codec: codec,
      localNode: localNode,
      peerDirectory: MembershipPeerDirectory(peerRegistry),
      entryRepository: entryRepository,
      timePort: timePort,
      messagePort: messagePort ?? localPort,
      localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
      onError: errors.add,
      onEntriesMerged:
          onEntriesMerged ??
          (channelId, streamId, entries, containsOutOfOrderEntries) async {
            mergedEntries.add(
              MergedEntriesRecord(
                channelId,
                streamId,
                entries,
                containsOutOfOrderEntries,
              ),
            );
          },
      hlcClock: hlcClock,
      gossipInterval: gossipInterval,
      adaptiveTimingEnabled: adaptiveTimingEnabled,
      maxMessageBytes: maxMessageBytes ?? GossipEngine.defaultMaxMessageBytes,
      random: random,
    );

    return GossipEngineTestHarness._(
      localNode: localNode,
      peerRegistry: peerRegistry,
      entryRepository: entryRepository,
      timePort: timePort,
      bus: bus,
      localPort: localPort,
      engine: engine,
      codec: codec,
      hlcClock: hlcClock,
      errors: errors,
      mergedEntries: mergedEntries,
    );
  }

  // Standalone builders (for tests needing custom dependencies)

  /// Builds a bare [GossipEngine] with injectable dependencies, for tests
  /// that need a custom repository or callbacks the harness doesn't expose.
  static GossipEngine buildEngine({
    required NodeId localNode,
    required PeerRegistry peerRegistry,
    required InMemoryTimePort timePort,
    required LocalNodeRepository localNodeRepository,
    ErrorCallback? onError,
    LogCallback? onLog,
    bool withHlcClock = false,
    int? maxMessageBytes,
    // Defaulting to v2 preserves what the existing suite pins; a later task wires
    // this to the real coordinator config default (v1).
    WireVersion wireVersion = WireVersion.v2,
  }) {
    final bus = InMemoryMessageBus();
    return GossipEngine(
      codec: SyncMessageCodec(wireVersion: wireVersion),
      localNode: localNode,
      peerDirectory: MembershipPeerDirectory(peerRegistry),
      entryRepository: InMemoryEntryRepository(),
      timePort: timePort,
      messagePort: InMemoryMessagePort(localNode, bus),
      localNodeRepository: localNodeRepository,
      onError: onError,
      onLog: onLog,
      hlcClock: withHlcClock ? HlcClock(TimeSource(timePort)) : null,
      maxMessageBytes: maxMessageBytes ?? GossipEngine.defaultMaxMessageBytes,
    );
  }

  /// Registers a channel with the given streams directly on [engine].
  static void registerChannel(
    GossipEngine engine,
    ChannelId channelId,
    List<StreamId> streamIds,
  ) {
    final channel = ChannelAggregate(
      id: channelId,
      localNode: engine.localNode,
    );
    for (final sid in streamIds) {
      channel.createStream(
        sid,
        const KeepAllRetention(),
        occurredAt: DateTime.now(),
      );
    }
    engine.setChannels({channelId: channel});
  }

  // Peer management

  /// Adds a peer to the registry and creates its message port.
  GossipTestPeer addPeer(String name) {
    final id = NodeId(name);
    peerRegistry.addPeer(id, occurredAt: DateTime.now());
    final port = InMemoryMessagePort(id, bus);
    final peer = GossipTestPeer(id, port);
    _peers.add(peer);
    return peer;
  }

  // Channel management

  /// Creates a channel with the given streams and registers it with the engine.
  ChannelAggregate createChannel(
    String channelName, {
    List<String> streamIds = const [],
  }) {
    final channelId = ChannelId(channelName);
    final channel = ChannelAggregate(id: channelId, localNode: localNode);
    for (final sid in streamIds) {
      channel.createStream(
        StreamId(sid),
        const KeepAllRetention(),
        occurredAt: DateTime.now(),
      );
    }
    _channels[channelId] = channel;
    engine.setChannels(Map.of(_channels));
    return channel;
  }

  /// Creates a channel with a single stream from already-typed ids and
  /// registers it with the engine. Thin wrapper around [createChannel] for
  /// tests that already have a [ChannelId]/[StreamId] in hand.
  Future<ChannelAggregate> createChannelWithStream(
    ChannelId channelId,
    StreamId streamId,
  ) async {
    final channel = ChannelAggregate(id: channelId, localNode: localNode);
    channel.createStream(
      streamId,
      const KeepAllRetention(),
      occurredAt: DateTime.now(),
    );
    _channels[channelId] = channel;
    engine.setChannels(Map.of(_channels));
    return channel;
  }

  // Entry management

  /// Appends a log entry to the entry repository.
  Future<void> appendEntry(
    ChannelId channelId,
    StreamId streamId,
    LogEntry entry,
  ) async {
    await entryRepository.append(channelId, streamId, entry);
  }

  /// Appends a locally-authored log entry directly to the entry repository,
  /// advancing this node's own high-water mark for [streamId] without going
  /// through the wire. Fixes the author to [localNode] so the resulting
  /// version vector reflects a local write (`{localNode: sequence}`) — the
  /// same fixture shape [appendEntry] gives peer-authored entries, but for
  /// tests that need "what do we, the responder, already have."
  Future<void> appendLocalEntry(
    ChannelId channelId,
    StreamId streamId, {
    required int sequence,
    int timestampMs = 1000,
  }) async {
    await entryRepository.append(
      channelId,
      streamId,
      LogEntry(
        author: localNode,
        sequence: sequence,
        timestamp: Hlc(timestampMs + sequence, 0),
        payload: Uint8List.fromList([0x42]),
      ),
    );
  }

  // Message helpers

  /// Starts capturing all decoded messages arriving at [peer].
  ///
  /// Returns a record of `(messages, subscription)`. Cancel the subscription
  /// when done.
  (List<dynamic>, StreamSubscription<IncomingMessage>) captureMessages(
    GossipTestPeer peer,
  ) {
    final messages = <dynamic>[];
    final sub = peer.port.incoming.listen((msg) {
      messages.add(codec.decode(msg.bytes));
    });
    return (messages, sub);
  }

  /// Delivers a [DeltaResponse] from [from] as a real wire message, driving
  /// it through [engine]'s actual incoming-message handling (the same path
  /// a live peer's push or reply takes) rather than calling
  /// `engine.handleDeltaResponse` directly. This matters for news-trigger
  /// tests: some `_recordNews()` call sites live in `_handleIncomingMessage`
  /// itself, not just in the handler it delegates to.
  ///
  /// Starts listening (idempotent) so the message is actually routed.
  ///
  /// The trailing `flush(3)` settles [engine]'s async handling chain
  /// (decode, merge, callback, any reply) before returning. Left as a
  /// fixed count rather than a [pumpUntil] condition: callers check
  /// different downstream effects of the same delivery (merged entries,
  /// pacing state, peer bookkeeping), and an empty `entries` push is a
  /// legitimate call with nothing to observably wait for — no single
  /// condition covers every caller's target.
  Future<void> deliverDeltaResponse({
    required GossipTestPeer from,
    required ChannelId channelId,
    required StreamId streamId,
    required List<LogEntry> entries,
    bool hasMore = false,
    VersionVector floor = VersionVector.empty,
  }) async {
    engine.startListening(Map.of(_channels));
    final response = DeltaResponse(
      sender: from.id,
      channelId: channelId,
      streamId: streamId,
      entries: entries,
      hasMore: hasMore,
      floor: floor,
    );
    await from.port.send(localNode, codec.encode(response));
    await flush(3);
  }

  /// Delivers a [DeltaRequest] from [from] as a real wire message, driving it
  /// through [engine]'s actual incoming-message handling. See
  /// [deliverDeltaResponse] for why this goes over the wire instead of
  /// calling `engine.handleDeltaRequest` directly.
  ///
  /// Starts listening (idempotent) so the message is actually routed.
  ///
  /// See [deliverDeltaResponse] for why the trailing `flush(3)` stays a
  /// fixed count: this request's handling ends in a computed reply plus
  /// pacing/bookkeeping side effects that different callers check
  /// individually, with no single shared observable.
  Future<void> deliverDeltaRequest({
    required GossipTestPeer from,
    required ChannelId channelId,
    required StreamId streamId,
    VersionVector? since,
  }) async {
    engine.startListening(Map.of(_channels));
    final request = DeltaRequest(
      sender: from.id,
      channelId: channelId,
      streamId: streamId,
      since: since ?? VersionVector.empty,
    );
    await from.port.send(localNode, codec.encode(request));
    await flush(3);
  }

  /// Delivers a [DigestRequest] from [from] as a real wire message, driving
  /// it through [engine]'s actual incoming-message handling. See
  /// [deliverDeltaResponse] for why this goes over the wire instead of
  /// calling `engine.handleDigestRequest` directly.
  ///
  /// Starts listening (idempotent) so the message is actually routed.
  /// Defaults to an empty digest list — fine for tests that only care
  /// about the responder-side exchange bookkeeping, not the reply content.
  ///
  /// See [deliverDeltaResponse] for why the trailing `flush(3)` stays a
  /// fixed count.
  Future<void> deliverDigestRequest({
    required GossipTestPeer from,
    List<ChannelDigest> digests = const [],
  }) async {
    engine.startListening(Map.of(_channels));
    final request = DigestRequest(sender: from.id, digests: digests);
    await from.port.send(localNode, codec.encode(request));
    await flush(3);
  }

  // Time helpers

  /// Yields the microtask queue [count] times.
  ///
  /// Stays a fixed-count settle rather than a [pumpUntil] condition: it's
  /// called both internally (by [deliverDeltaResponse],
  /// [deliverDeltaRequest], [deliverDigestRequest] — see their docs) and
  /// directly by dozens of tests across this suite, each waiting on its
  /// own downstream effect of whatever it just sent or triggered. No
  /// single observable condition covers all of them.
  Future<void> flush([int count = 1]) async {
    for (var i = 0; i < count; i++) {
      await Future.delayed(Duration.zero);
    }
  }

  // Lifecycle

  void startListening() => engine.startListening(Map.of(_channels));

  void stopListening() => engine.stopListening();

  /// Disposes all resources: stops listening and closes all peer ports.
  Future<void> dispose() async {
    engine.stopListening();
    engine.stop();
    for (final peer in _peers) {
      await peer.port.close();
    }
  }
}
