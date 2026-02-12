import 'dart:async';

import 'package:gossip/src/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/errors/sync_error.dart';
import 'package:gossip/src/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/domain/services/hlc_clock.dart';
import 'package:gossip/src/domain/services/time_source.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/ports/message_port.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_local_node_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:gossip/src/protocol/gossip_engine.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';

// ---------------------------------------------------------------------------
// Test peer
// ---------------------------------------------------------------------------

/// A peer node managed by the gossip engine test harness.
class GossipTestPeer {
  final NodeId id;
  final InMemoryMessagePort port;

  GossipTestPeer(this.id, this.port);
}

// ---------------------------------------------------------------------------
// Merged entries record
// ---------------------------------------------------------------------------

/// Records a single onEntriesMerged callback invocation.
class MergedEntriesRecord {
  final ChannelId channelId;
  final StreamId streamId;
  final List<LogEntry> entries;

  MergedEntriesRecord(this.channelId, this.streamId, this.entries);
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

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
  final ProtocolCodec codec = ProtocolCodec();
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
    required this.hlcClock,
    required this.errors,
    required this.mergedEntries,
  });

  /// Creates a harness with the given configuration.
  factory GossipEngineTestHarness({
    String localName = 'local',
    Duration? gossipInterval,
    bool adaptiveTimingEnabled = false,
    bool withHlcClock = false,
    MessagePort? messagePort,
  }) {
    final localNode = NodeId(localName);
    final peerRegistry = PeerRegistry(
      localNode: localNode,
      initialIncarnation: 0,
    );
    final timePort = InMemoryTimePort();
    final bus = InMemoryMessageBus();
    final localPort = InMemoryMessagePort(localNode, bus);
    final entryRepository = InMemoryEntryRepository();
    final errors = <SyncError>[];
    final mergedEntries = <MergedEntriesRecord>[];

    HlcClock? hlcClock;
    if (withHlcClock) {
      hlcClock = HlcClock(TimeSource(timePort));
    }

    final engine = GossipEngine(
      localNode: localNode,
      peerRegistry: peerRegistry,
      entryRepository: entryRepository,
      timePort: timePort,
      messagePort: messagePort ?? localPort,
      localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
      onError: errors.add,
      onEntriesMerged: (channelId, streamId, entries) async {
        mergedEntries.add(MergedEntriesRecord(channelId, streamId, entries));
      },
      hlcClock: hlcClock,
      gossipInterval: gossipInterval,
      adaptiveTimingEnabled: adaptiveTimingEnabled,
    );

    return GossipEngineTestHarness._(
      localNode: localNode,
      peerRegistry: peerRegistry,
      entryRepository: entryRepository,
      timePort: timePort,
      bus: bus,
      localPort: localPort,
      engine: engine,
      hlcClock: hlcClock,
      errors: errors,
      mergedEntries: mergedEntries,
    );
  }

  // -------------------------------------------------------------------------
  // Peer management
  // -------------------------------------------------------------------------

  /// Adds a peer to the registry and creates its message port.
  GossipTestPeer addPeer(String name) {
    final id = NodeId(name);
    peerRegistry.addPeer(id, occurredAt: DateTime.now());
    final port = InMemoryMessagePort(id, bus);
    final peer = GossipTestPeer(id, port);
    _peers.add(peer);
    return peer;
  }

  // -------------------------------------------------------------------------
  // Channel management
  // -------------------------------------------------------------------------

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

  // -------------------------------------------------------------------------
  // Entry management
  // -------------------------------------------------------------------------

  /// Appends a log entry to the entry repository.
  Future<void> appendEntry(
    ChannelId channelId,
    StreamId streamId,
    LogEntry entry,
  ) async {
    await entryRepository.append(channelId, streamId, entry);
  }

  // -------------------------------------------------------------------------
  // Message helpers
  // -------------------------------------------------------------------------

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

  // -------------------------------------------------------------------------
  // Time helpers
  // -------------------------------------------------------------------------

  /// Yields the microtask queue [count] times.
  Future<void> flush([int count = 1]) async {
    for (var i = 0; i < count; i++) {
      await Future.delayed(Duration.zero);
    }
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

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
