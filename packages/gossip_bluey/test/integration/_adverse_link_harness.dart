import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';
import 'package:gossip_bluey/src/application/services/auto_connect_policy.dart';
import 'package:gossip_bluey/src/application/services/connection_manager.dart';
import 'package:gossip_bluey/src/application/services/discovery_service.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/infrastructure/codec/frame_codec.dart';
import 'package:gossip_bluey/src/infrastructure/ports/bluey_message_port.dart';

import '../fakes/fake_bluey_port.dart';
import '_coordinator_helpers.dart';

/// Fixed short gossip interval so adverse-link scenarios converge (and
/// re-converge after a fault) within a couple of seconds of real time.
const CoordinatorConfig fastGossipConfig = CoordinatorConfig(
  gossipInterval: Duration(milliseconds: 200),
);

/// True when [chunk] begins a new frame (starts with the GSP1 magic).
/// Used by fault injectors to find message boundaries in the chunk
/// stream without guessing at send ordering.
bool chunkStartsFrame(Uint8List chunk) {
  if (chunk.length < kMagicSize) return false;
  for (var i = 0; i < kMagicSize; i++) {
    if (chunk[i] != kMagicBytes[i]) return false;
  }
  return true;
}

/// Total framed length (header + payload) declared by a frame's header
/// chunk. Only meaningful when [chunkStartsFrame] is true and the chunk
/// carries the full 8-byte header.
int declaredFrameLength(Uint8List chunk) {
  final view = ByteData.sublistView(chunk);
  return kFrameHeaderSize + view.getUint32(kMagicSize, Endian.big);
}

/// One node of the full sync stack under test: a real core [Coordinator]
/// driving a [BlueyMessagePort] → [ConnectionManager] →
/// [DiscoveryService]/[AutoConnectPolicy] → [FakeBlueyPort].
///
/// The wiring is identical to `BlueyTransport.testing` (facade minus the
/// peer-event relay), but exposes the knobs the facade hard-codes — the
/// per-chunk send timeout and the auto-connect backoff windows — so
/// adverse-link scenarios can run fast and deterministically.
class AdverseLinkNode {
  AdverseLinkNode._({
    required this.nodeId,
    required this.serviceUuid,
    required this.port,
    required this.registry,
    required this.metrics,
    required this.manager,
    required this.discovery,
    required this.autoConnect,
    required this.coordinator,
  }) {
    _connectionErrorSub = manager.errors.listen(connectionErrors.add);
    _syncErrorSub = coordinator.errors.listen(syncErrors.add);
  }

  final NodeId nodeId;
  final ServiceUuid serviceUuid;
  final FakeBlueyPort port;
  final ConnectionRegistry registry;
  final BlueyMetrics metrics;
  final ConnectionManager manager;
  final DiscoveryService discovery;
  final AutoConnectPolicy autoConnect;
  final Coordinator coordinator;

  /// Every [ConnectionError] emitted by the transport layer, in order.
  /// Adverse-link tests assert failures surface here instead of being
  /// swallowed.
  final List<ConnectionError> connectionErrors = [];

  /// Every [SyncError] emitted by the core coordinator, in order (e.g.
  /// `messageCorrupted` when a mangled frame reaches the protocol codec).
  final List<SyncError> syncErrors = [];

  late final StreamSubscription<ConnectionError> _connectionErrorSub;
  late final StreamSubscription<SyncError> _syncErrorSub;

  static Future<AdverseLinkNode> spawn({
    required NodeId nodeId,
    required FakeBlueyNetwork network,
    required ServiceUuid serviceUuid,
    Duration sendTimeout = ConnectionManager.defaultSendTimeout,
    Duration initialBackoff = const Duration(seconds: 1),
    Duration maxBackoff = const Duration(seconds: 60),
    int chunkSize = 200,
  }) async {
    final port = FakeBlueyPort(localNodeId: nodeId, network: network)
      ..chunkSize = chunkSize;
    final registry = ConnectionRegistry();
    final metrics = BlueyMetrics();
    final manager = ConnectionManager(
      port: port,
      registry: registry,
      metrics: metrics,
      localNodeId: nodeId,
      sendTimeout: sendTimeout,
    );
    final discovery = DiscoveryService(port: port, serviceUuid: serviceUuid);
    final autoConnect = AutoConnectPolicy(
      discovery: discovery,
      connections: manager,
      registry: registry,
      now: DateTime.now,
      initialBackoff: initialBackoff,
      maxBackoff: maxBackoff,
    );
    final coordinator = await spawnCoordinator(
      nodeId: nodeId,
      messagePort: BlueyMessagePort(manager),
      config: fastGossipConfig,
    );
    return AdverseLinkNode._(
      nodeId: nodeId,
      serviceUuid: serviceUuid,
      port: port,
      registry: registry,
      metrics: metrics,
      manager: manager,
      discovery: discovery,
      autoConnect: autoConnect,
      coordinator: coordinator,
    );
  }

  /// Brings the BLE side up. Mesh nodes advertise and discover; a
  /// star hub advertises only ([discover] false), a spoke discovers only
  /// ([advertise] false). Discovery always runs in auto-connect mode.
  Future<void> start({bool advertise = true, bool discover = true}) async {
    if (advertise) {
      await port.startAdvertising(
        serviceUuid: serviceUuid,
        displayName: nodeId.value.substring(0, 8),
        localNodeId: nodeId,
      );
    }
    if (discover) {
      await discovery.start();
      autoConnect.setMode(ConnectionMode.auto);
    }
  }

  /// Whether the transport currently holds an active link to [peer].
  bool isLinkedTo(NodeId peer) => registry.contains(peer);

  /// Creates the shared channel/stream on this node and registers
  /// [peers] both as channel members and gossip peers. Returns the local
  /// stream handle for appends.
  Future<EventStream> joinChannel({
    required ChannelId channelId,
    required StreamId streamId,
    required List<NodeId> peers,
  }) async {
    final channel = await coordinator.createChannel(channelId);
    final stream = await channel.getOrCreateStream(streamId);
    for (final peer in peers) {
      await channel.addMember(peer);
      await coordinator.addPeer(peer);
    }
    return stream;
  }

  /// Current entries of the shared stream (empty when the channel has
  /// not been created locally yet).
  Future<List<LogEntry>> entriesOf(
    ChannelId channelId,
    StreamId streamId,
  ) async {
    final channel = coordinator.getChannel(channelId);
    if (channel == null) return const [];
    final stream = await channel.getOrCreateStream(streamId);
    return (await stream.getAll()).cast<LogEntry>();
  }

  Future<void> dispose() async {
    await _connectionErrorSub.cancel();
    await _syncErrorSub.cancel();
    await coordinator.dispose();
    await autoConnect.dispose();
    await discovery.dispose();
    await manager.dispose();
    await port.dispose();
  }
}

/// Waits until [node]'s view of the shared stream holds at least
/// [count] entries.
Future<void> waitForEntryCount(
  AdverseLinkNode node,
  ChannelId channelId,
  StreamId streamId,
  int count, {
  Duration timeout = const Duration(seconds: 10),
  String? what,
}) {
  return waitFor(
    () async => (await node.entriesOf(channelId, streamId)).length >= count,
    timeout: timeout,
    what: what ?? '$count entries on ${node.nodeId.value.substring(0, 8)}',
  );
}
