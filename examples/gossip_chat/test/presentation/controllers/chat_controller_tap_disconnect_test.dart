// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';

import 'package:bluey/bluey.dart' as bluey;
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart' as gossip;
import 'package:gossip_bluey/gossip_bluey.dart';
import 'package:gossip_chat/application/services/chat_service.dart';
import 'package:gossip_chat/application/services/connection_service.dart';
import 'package:gossip_chat/application/services/gossip_config_service.dart';
import 'package:gossip_chat/application/services/metrics_service.dart';
import 'package:gossip_chat/application/services/sync_service.dart';
import 'package:gossip_chat/domain/entities/typing_event.dart';
import 'package:gossip_chat/presentation/controllers/chat_controller.dart';
import 'package:gossip_chat/presentation/view_models/discovered_peer.dart';
import 'package:gossip_chat/presentation/view_models/metrics_state.dart';

/// Minimal fake [ConnectionService] that implements only the surface the
/// [ChatController] uses. We `implements` rather than `extends` so the
/// real super constructor (which wires the transport) never runs.
class FakeConnectionService implements ConnectionService {
  FakeConnectionService();

  final StreamController<PeerEvent> peerEventsCtrl =
      StreamController<PeerEvent>.broadcast();
  final StreamController<ScanCandidate> candidateEventsCtrl =
      StreamController<ScanCandidate>.broadcast();
  final StreamController<BluetoothAdapterState> bluetoothStateCtrl =
      StreamController<BluetoothAdapterState>.broadcast();
  final StreamController<bluey.AdvertisingState> advertisingStateCtrl =
      StreamController<bluey.AdvertisingState>.broadcast();
  final StreamController<bluey.ScanState> scanStateCtrl =
      StreamController<bluey.ScanState>.broadcast();

  /// Candidates the controller will see via [currentCandidates].
  final List<ScanCandidate> stagedCandidates = [];

  /// Programmable result for the next [connectTo] call. Either a
  /// [gossip.NodeId] or an [Exception] to throw. Optional delay before
  /// resolving lets tests simulate connectTo-in-flight races.
  gossip.NodeId? nextConnectResult;
  Object? nextConnectError;
  Duration connectDelay = Duration.zero;

  /// disconnect() behavior: succeed by default. If [disconnectError] is
  /// set, throws it instead.
  Object? disconnectError;

  int disconnectCallCount = 0;
  final List<ScanCandidate> connectCalls = [];
  final List<BleAddress> connectByAddressCalls = [];

  @override
  Future<gossip.NodeId> connectTo(ScanCandidate candidate) async {
    connectCalls.add(candidate);
    if (connectDelay > Duration.zero) {
      await Future<void>.delayed(connectDelay);
    }
    if (nextConnectError != null) {
      throw nextConnectError!;
    }
    return nextConnectResult!;
  }

  @override
  Future<gossip.NodeId> connectByAddress(BleAddress address) async {
    connectByAddressCalls.add(address);
    // Mirror the real transport: if no candidate is known for the
    // address, throw StateError. Otherwise, defer to the same delay /
    // result / error knobs used by connectTo.
    final hasCandidate =
        stagedCandidates.any((c) => c.address == address);
    if (!hasCandidate) {
      throw StateError('no candidate currently known for $address');
    }
    if (connectDelay > Duration.zero) {
      await Future<void>.delayed(connectDelay);
    }
    if (nextConnectError != null) {
      throw nextConnectError!;
    }
    return nextConnectResult!;
  }

  @override
  Future<void> disconnect(gossip.NodeId nodeId) async {
    disconnectCallCount++;
    if (disconnectError != null) {
      throw disconnectError!;
    }
  }

  @override
  Stream<PeerEvent> get peerEvents => peerEventsCtrl.stream;

  @override
  Stream<ScanCandidate> get candidateEvents => candidateEventsCtrl.stream;

  @override
  Stream<BluetoothAdapterState> get bluetoothStateStream =>
      bluetoothStateCtrl.stream;

  @override
  Stream<bluey.AdvertisingState> get advertisingStateStream =>
      advertisingStateCtrl.stream;

  @override
  Stream<bluey.ScanState> get scanStateStream => scanStateCtrl.stream;

  @override
  List<ScanCandidate> get currentCandidates => stagedCandidates;

  @override
  int get connectedPeerCount => 0;

  @override
  ConnectionMode get connectionMode => ConnectionMode.manual;

  @override
  BluetoothAdapterState get bluetoothAdapterState => BluetoothAdapterState.on;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Minimal fake [SyncService]. The controller reads `events` (Stream) and
/// `peers` (List). disconnectPeer's self-heal probe reads `peers`.
class FakeSyncService implements SyncService {
  FakeSyncService();

  final StreamController<gossip.DomainEvent> eventsCtrl =
      StreamController<gossip.DomainEvent>.broadcast();

  List<gossip.Peer> peerList = [];

  @override
  Stream<gossip.DomainEvent> get events => eventsCtrl.stream;

  @override
  List<gossip.Peer> get peers => peerList;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Minimal fake [ChatService]. The controller's constructor refreshes
/// channels, so we surface an empty channel list.
class FakeChatService implements ChatService {
  FakeChatService(this._localNodeId);

  final gossip.NodeId _localNodeId;

  @override
  gossip.NodeId get localNodeId => _localNodeId;

  @override
  List<gossip.ChannelId> get channelIds => const [];

  @override
  Future<Map<gossip.NodeId, TypingEvent>> getTypingUsers(
    gossip.ChannelId channelId,
  ) async => {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Minimal fake [MetricsService].
class FakeMetricsService implements MetricsService {
  @override
  void sampleRates() {}

  @override
  Future<MetricsState> getMetrics() async => MetricsState.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final addr = BleAddress('AA:BB:CC:DD:EE:FF');
  final localNodeId = gossip.NodeId('00000000-0000-0000-0000-0000000000aa');
  final remoteNodeId = gossip.NodeId('00000000-0000-0000-0000-0000000000bb');
  final lastSeen = DateTime.utc(2026, 6, 3, 12);

  group('ChatController.tapPeer (fix 1)', () {
    test('rekeys via connectTo return value (not via PeerOpened/hint)',
        () async {
      final connection = FakeConnectionService();
      final sync = FakeSyncService();
      final chat = FakeChatService(localNodeId);
      final metrics = FakeMetricsService();

      // Stage a candidate that the controller can find via currentCandidates.
      final candidate = ScanCandidate(address: addr, lastSeen: lastSeen);
      connection.stagedCandidates.add(candidate);

      // Configure connectTo to resolve to remoteNodeId after a short delay
      // so we can observe the connecting -> connected transition.
      connection.nextConnectResult = remoteNodeId;
      connection.connectDelay = const Duration(milliseconds: 5);

      final controller = ChatController(
        chatService: chat,
        connectionService: connection,
        syncService: sync,
        metricsService: metrics,
        configService: GossipConfigService(),
      );

      // Seed a discovered peer (as if it had been merged from a scan
      // candidate). The controller's _peers map keys it by BleAddress.
      final discovered = DiscoveredPeer(
        address: addr,
        lastSeenAt: lastSeen,
        status: DiscoveredPeerStatus.discovered,
      );

      // Drive a scan candidate through the public stream so the
      // controller populates _peers under the BleAddress key.
      connection.candidateEventsCtrl.add(
        ScanCandidate(address: addr, lastSeen: lastSeen),
      );
      // Let the stream listener run.
      await Future<void>.delayed(Duration.zero);
      expect(controller.peers, hasLength(1));
      expect(controller.peers.first.address, addr);
      expect(controller.peers.first.nodeId, isNull);

      // Tap the discovered peer. tapPeer should rekey synchronously off
      // connectTo's return value — even without any PeerOpened event.
      await controller.tapPeer(discovered);

      // No PeerOpened event was emitted. The entry must still have been
      // rekeyed to remoteNodeId and marked connected.
      expect(controller.peers, hasLength(1));
      final p = controller.peers.first;
      expect(p.nodeId, remoteNodeId);
      expect(p.address, addr);
      expect(p.status, DiscoveredPeerStatus.connected);

      controller.dispose();
    });

    test('transitions to failed when no candidate is known for the address',
        () async {
      final connection = FakeConnectionService();
      final sync = FakeSyncService();
      final chat = FakeChatService(localNodeId);
      final metrics = FakeMetricsService();

      // No candidates staged: connectByAddress will throw StateError.
      expect(connection.stagedCandidates, isEmpty);

      final controller = ChatController(
        chatService: chat,
        connectionService: connection,
        syncService: sync,
        metricsService: metrics,
        configService: GossipConfigService(),
      );

      // Seed a discovered peer via a scan candidate event (so _peers
      // contains an entry under the BleAddress key), then drop it from
      // stagedCandidates by *not* adding it. The candidate event drives
      // the controller's _onCandidate path; stagedCandidates is what
      // connectByAddress consults.
      connection.candidateEventsCtrl
          .add(ScanCandidate(address: addr, lastSeen: lastSeen));
      await Future<void>.delayed(Duration.zero);
      expect(controller.peers, hasLength(1));

      final discovered = DiscoveredPeer(
        address: addr,
        lastSeenAt: lastSeen,
        status: DiscoveredPeerStatus.discovered,
      );
      await controller.tapPeer(discovered);

      expect(connection.connectByAddressCalls, hasLength(1));
      expect(controller.peers, hasLength(1));
      expect(controller.peers.first.status, DiscoveredPeerStatus.failed);

      controller.dispose();
    });
  });

  group('ChatController.disconnectPeer (fix 2)', () {
    test('self-heals to unreachable if PeerClosed never fires', () async {
      final connection = FakeConnectionService();
      final sync = FakeSyncService();
      final chat = FakeChatService(localNodeId);
      final metrics = FakeMetricsService();

      // disconnect() succeeds but emits no PeerClosed event and the peer
      // is NOT present in the sync registry afterward.
      sync.peerList = const [];

      final controller = ChatController(
        chatService: chat,
        connectionService: connection,
        syncService: sync,
        metricsService: metrics,
        configService: GossipConfigService(),
      );

      // Seed a connected peer keyed by NodeId by emitting a PeerConnected
      // event through the connection service stream.
      connection.peerEventsCtrl.add(PeerConnected(remoteNodeId, address: addr));
      await Future<void>.delayed(Duration.zero);
      expect(controller.peers, hasLength(1));
      expect(controller.peers.first.nodeId, remoteNodeId);
      expect(controller.peers.first.status, DiscoveredPeerStatus.connected);

      // Disconnect. Since no PeerClosed event arrives, the self-heal must
      // transition the row to unreachable rather than leaving it stuck
      // at disconnecting.
      await controller.disconnectPeer(remoteNodeId);

      expect(connection.disconnectCallCount, 1);
      expect(controller.peers, hasLength(1));
      expect(controller.peers.first.status, DiscoveredPeerStatus.unreachable);

      controller.dispose();
    });
  });
}
