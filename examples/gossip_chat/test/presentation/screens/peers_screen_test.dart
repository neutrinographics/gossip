// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';

import 'package:bluey/bluey.dart' as bluey;
import 'package:flutter/material.dart';
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
import 'package:gossip_chat/presentation/screens/peers_screen.dart';
import 'package:gossip_chat/presentation/view_models/metrics_state.dart';
import 'package:gossip_chat/presentation/widgets/peer_status_pill.dart';
import 'package:gossip_chat/presentation/widgets/topology_controls.dart';

/// Minimal [ConnectionService] fake (mirrors the one in
/// `chat_controller_tap_disconnect_test.dart`). We `implements` so the
/// real super constructor never runs.
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

  final List<ScanCandidate> stagedCandidates = [];

  gossip.NodeId? nextConnectResult;
  ConnectionMode mode = ConnectionMode.manual;

  final List<BleAddress> connectByAddressCalls = [];
  int setConnectionModeCalls = 0;
  int startAdvertisingCalls = 0;
  int stopAdvertisingCalls = 0;
  int startDiscoveryCalls = 0;
  int stopDiscoveryCalls = 0;

  @override
  Future<gossip.NodeId> connectTo(ScanCandidate candidate) async {
    return nextConnectResult!;
  }

  @override
  Future<gossip.NodeId> connectByAddress(BleAddress address) async {
    connectByAddressCalls.add(address);
    return nextConnectResult!;
  }

  @override
  Future<void> disconnect(gossip.NodeId nodeId) async {}

  @override
  Future<void> startAdvertising() async => startAdvertisingCalls++;

  @override
  Future<void> stopAdvertising() async => stopAdvertisingCalls++;

  @override
  Future<void> startDiscovery() async => startDiscoveryCalls++;

  @override
  Future<void> stopDiscovery() async => stopDiscoveryCalls++;

  @override
  void setConnectionMode(ConnectionMode mode) {
    setConnectionModeCalls++;
    this.mode = mode;
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
  ConnectionMode get connectionMode => mode;

  @override
  BluetoothAdapterState get bluetoothAdapterState => BluetoothAdapterState.on;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSyncService implements SyncService {
  final StreamController<gossip.DomainEvent> eventsCtrl =
      StreamController<gossip.DomainEvent>.broadcast();

  @override
  Stream<gossip.DomainEvent> get events => eventsCtrl.stream;

  @override
  List<gossip.Peer> get peers => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

class FakeMetricsService implements MetricsService {
  @override
  void sampleRates() {}

  @override
  Future<MetricsState> getMetrics() async => MetricsState.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _Bundle = ({
  ChatController controller,
  FakeConnectionService connection,
  FakeSyncService sync,
});

_Bundle _makeBundle() {
  final connection = FakeConnectionService();
  final sync = FakeSyncService();
  final chat = FakeChatService(
    gossip.NodeId('00000000-0000-0000-0000-0000000000aa'),
  );
  final metrics = FakeMetricsService();
  final controller = ChatController(
    chatService: chat,
    connectionService: connection,
    syncService: sync,
    metricsService: metrics,
    configService: GossipConfigService(),
  );
  return (controller: controller, connection: connection, sync: sync);
}

Future<void> _pump(WidgetTester t, ChatController controller) async {
  await t.pumpWidget(
    MaterialApp(home: PeersScreen(controller: controller)),
  );
  // Let stream listeners flush (initial bluetooth/adv/scan state, etc.).
  await t.pump();
}

void main() {
  final addr = BleAddress('AA:BB:CC:DD:EE:FF');
  final remoteNodeId = gossip.NodeId('00000000-0000-0000-0000-0000000000bb');
  final lastSeen = DateTime.utc(2026, 6, 3, 12);

  group('PeersScreen', () {
    testWidgets('renders empty state when no direct or indirect peers',
        (t) async {
      final bundle = _makeBundle();

      // Set bluetooth on so the empty-state path falls through to the
      // "no peers" branch.
      bundle.connection.bluetoothStateCtrl.add(BluetoothAdapterState.on);
      await _pump(t, bundle.controller);

      // Default scan state (stopped) → "No peers found".
      expect(find.text('No peers found'), findsOneWidget);
      expect(find.byType(TopologyControls), findsOneWidget);

      bundle.controller.dispose();
    });

    testWidgets('renders a discovered peer with "Nearby" pill', (t) async {
      final bundle = _makeBundle();

      bundle.connection.bluetoothStateCtrl.add(BluetoothAdapterState.on);
      await t.pump();

      // Drive a scan candidate so the controller stores a discovered peer.
      bundle.connection.candidateEventsCtrl.add(
        ScanCandidate(address: addr, lastSeen: lastSeen, displayName: 'Alice'),
      );

      await _pump(t, bundle.controller);

      expect(find.text('Alice'), findsOneWidget);
      expect(find.byType(PeerStatusPill), findsOneWidget);
      // PeerStatusPill for the discovered peer renders the "Nearby"
      // label (distinct from the "Nearby" section header text).
      expect(
        find.descendant(
          of: find.byType(PeerStatusPill),
          matching: find.text('Nearby'),
        ),
        findsOneWidget,
      );

      bundle.controller.dispose();
    });

    testWidgets('renders a connected peer with "Connected" pill', (t) async {
      final bundle = _makeBundle();

      bundle.connection.bluetoothStateCtrl.add(BluetoothAdapterState.on);
      await t.pump();

      // PeerConnected (no prior candidate): merges directly under NodeId.
      bundle.connection.peerEventsCtrl
          .add(PeerConnected(remoteNodeId, displayName: 'Bob'));

      await _pump(t, bundle.controller);

      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget); // pill label

      bundle.controller.dispose();
    });

    testWidgets('tapping a discovered peer calls tapPeer (connectByAddress)',
        (t) async {
      final bundle = _makeBundle();

      bundle.connection.bluetoothStateCtrl.add(BluetoothAdapterState.on);
      await t.pump();

      // Stage a candidate so connectByAddress would succeed; the test only
      // needs to assert that connectByAddress was invoked.
      final candidate =
          ScanCandidate(address: addr, lastSeen: lastSeen, displayName: 'Cara');
      bundle.connection.stagedCandidates.add(candidate);
      bundle.connection.nextConnectResult = remoteNodeId;
      bundle.connection.candidateEventsCtrl.add(candidate);

      await _pump(t, bundle.controller);

      await t.tap(find.text('Cara'));
      // tapPeer is async; let the awaits settle. Use pump() rather than
      // pumpAndSettle() because the controller has a periodic timer that
      // would make pumpAndSettle never resolve.
      await t.pump();
      await t.pump();

      expect(bundle.connection.connectByAddressCalls, contains(addr));

      bundle.controller.dispose();
    });

    testWidgets('TopologyControls reflects controller state', (t) async {
      final bundle = _makeBundle();

      bundle.connection.bluetoothStateCtrl.add(BluetoothAdapterState.on);
      bundle.connection.advertisingStateCtrl
          .add(bluey.AdvertisingState.advertising);
      bundle.connection.scanStateCtrl.add(bluey.ScanState.scanning);
      await _pump(t, bundle.controller);

      final controls = t.widget<TopologyControls>(find.byType(TopologyControls));
      expect(controls.advertisingState, bluey.AdvertisingState.advertising);
      expect(controls.scanState, bluey.ScanState.scanning);
      expect(controls.enabled, isTrue);

      bundle.controller.dispose();
    });

    testWidgets('TopologyControls is disabled when bluetooth is off',
        (t) async {
      final bundle = _makeBundle();

      bundle.connection.bluetoothStateCtrl.add(BluetoothAdapterState.off);
      await _pump(t, bundle.controller);

      final controls = t.widget<TopologyControls>(find.byType(TopologyControls));
      expect(controls.enabled, isFalse);

      bundle.controller.dispose();
    });
  });
}
