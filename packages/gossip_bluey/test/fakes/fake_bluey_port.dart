import 'dart:async';
import 'dart:typed_data';

import 'package:bluey/bluey.dart' as bluey;
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/errors/not_a_bluey_peer_exception.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';
import 'package:gossip_bluey/src/domain/value_objects/bluetooth_adapter_state.dart';
import 'package:gossip_bluey/src/domain/value_objects/discovered_peer.dart';
import 'package:gossip_bluey/src/domain/value_objects/scan_candidate.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';

final _testCandidateInstant = DateTime.utc(2026, 1, 1);

/// In-memory shared bus that lets multiple [FakeBlueyPort]s find,
/// connect to, and exchange data with each other in tests.
class FakeBlueyNetwork {
  final Map<NodeId, FakeBlueyPort> _ports = {};

  void register(FakeBlueyPort port) {
    _ports[port.localNodeId] = port;
  }

  void unregister(NodeId nodeId) {
    _ports.remove(nodeId);
  }

  Iterable<FakeBlueyPort> advertisingPeersFor(ServiceUuid serviceUuid) sync* {
    for (final p in _ports.values) {
      if (p._isAdvertisingInternal &&
          p._advertisedServiceUuid == serviceUuid) {
        yield p;
      }
    }
  }

  FakeBlueyPort? lookup(NodeId nodeId) => _ports[nodeId];

  /// Yield ScanCandidates for every advertising peer except [self].
  /// The fake uses each port's NodeId as its BLE address (as a string)
  /// since there's no real address space — this keeps tests simple.
  Iterable<ScanCandidate> scanCandidatesFor(
    ServiceUuid serviceUuid,
    NodeId self,
  ) sync* {
    for (final p in _ports.values) {
      if (p.localNodeId == self) continue;
      if (!p._isAdvertisingInternal) continue;
      if (p._advertisedServiceUuid != serviceUuid) continue;
      yield ScanCandidate(
        address: BleAddress(p.localNodeId.value),
        displayName: p._advertisedDisplayName,
        rssi: -50,
        lastSeen: _testCandidateInstant,
      );
    }
  }
}

class FakeBlueyPort implements BlueyPort {
  FakeBlueyPort({required this.localNodeId, required this.network}) {
    network.register(this);
  }

  final NodeId localNodeId;
  final FakeBlueyNetwork network;

  final StreamController<BlueyPortEvent> _events =
      StreamController<BlueyPortEvent>.broadcast();
  bluey.AdvertisingState _advertisingState = bluey.AdvertisingState.idle;
  bluey.ScanState _scanState = bluey.ScanState.stopped;
  final StreamController<bluey.AdvertisingState> _advertisingStateChanges =
      StreamController<bluey.AdvertisingState>.broadcast();
  final StreamController<bluey.ScanState> _scanStateChanges =
      StreamController<bluey.ScanState>.broadcast();
  ServiceUuid? _advertisedServiceUuid;
  String? _advertisedDisplayName;
  final Set<NodeId> _connectedAsCentral = {};
  final Set<NodeId> _connectedAsPeripheral = {};

  /// Internal convenience: peers are visible to network scans iff
  /// advertising state is [bluey.AdvertisingState.advertising].
  bool get _isAdvertisingInternal =>
      _advertisingState == bluey.AdvertisingState.advertising;

  @override
  bluey.AdvertisingState get advertisingState => _advertisingState;

  @override
  Stream<bluey.AdvertisingState> get advertisingStateStream =>
      Stream.multi((controller) {
        controller.add(_advertisingState);
        final sub = _advertisingStateChanges.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = sub.cancel;
      });

  @override
  bluey.ScanState get scanState => _scanState;

  @override
  Stream<bluey.ScanState> get scanStateStream => Stream.multi((controller) {
    controller.add(_scanState);
    final sub = _scanStateChanges.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  /// Test hook: drive an advertising-state transition. Updates the
  /// cached value and emits on [advertisingStateStream].
  void setAdvertisingStateForTest(bluey.AdvertisingState s) {
    _advertisingState = s;
    if (!_advertisingStateChanges.isClosed) {
      _advertisingStateChanges.add(s);
    }
  }

  /// Test hook: drive a scan-state transition.
  void setScanStateForTest(bluey.ScanState s) {
    _scanState = s;
    if (!_scanStateChanges.isClosed) {
      _scanStateChanges.add(s);
    }
  }

  BluetoothAdapterState _adapterState = BluetoothAdapterState.on;
  final StreamController<BluetoothAdapterState> _adapterStateController =
      StreamController<BluetoothAdapterState>.broadcast();

  /// Test hook: inject a connect failure for target node.
  bool Function(NodeId target)? connectFailureInjector;

  /// Test hook: latency added to discovery.
  Duration discoveryLatency = Duration.zero;

  /// Test hook: invoked at the start of every discoverPeers call.
  void Function(BlueyPort port)? onDiscoverPeers;

  /// Test hook: invoked at the start of every connectAndIdentify call.
  void Function(ScanCandidate candidate)? onConnectAndIdentify;

  /// Test hook: latency added to connectAndIdentify.
  Duration connectAndIdentifyDelay = Duration.zero;

  /// Test hook: when the predicate returns true for an address, the
  /// next connectAndIdentify call for that address throws a generic
  /// failure (transient).
  bool Function(BleAddress address)? connectAndIdentifyFailureInjector;

  /// Test hook: per-address override that throws a specific exception
  /// from connectAndIdentify (e.g. to simulate
  /// ConnectionManager.connectTo's reentrancy guard throwing StateError).
  final Map<BleAddress, Object> _connectAndIdentifyErrors = {};

  /// Configures [connectAndIdentify] to throw [error] the next time it
  /// is called with a candidate matching [address].
  void injectConnectAndIdentifyError(BleAddress address, Object error) {
    _connectAndIdentifyErrors[address] = error;
  }

  /// Number of times [connectAndIdentify] has been called. Used by
  /// tests asserting whether a retry was attempted.
  int connectAndIdentifyCallCount = 0;

  /// Test hook: when the predicate returns true for an address, the
  /// next connectAndIdentify call for that address throws
  /// [NotABlueyPeerException].
  bool Function(BleAddress address)? notABlueyPeerInjector;

  /// Test hook: when set and returns true for a payload, the fake
  /// silently drops it from `sendData`. Used to simulate a single
  /// dropped chunk on writes-without-response.
  bool Function(NodeId target, Uint8List data)? chunkDropInjector;

  StreamController<ScanCandidate>? _scanController;
  Timer? _scanRebroadcastTimer;

  // ---- Test-only helpers ----

  /// Number of times [scanForCandidates] has been called. Useful for
  /// asserting idempotent start behaviour in services that own the scan
  /// subscription.
  int scanForCandidatesCallCount = 0;

  /// Number of times [stopScan] has been called.
  int stopScanCallCount = 0;

  /// Drive a scan emission for the open scan stream (test-only). Used
  /// to deliver candidates synchronously in tests without depending on
  /// network advertise state.
  void emitScanCandidate(ScanCandidate candidate) {
    _scanController?.add(candidate);
  }

  /// Alias for [emitScanCandidate]. Newer tests use the shorter name.
  void emitCandidate(ScanCandidate candidate) => emitScanCandidate(candidate);

  /// Drive a raw port event (test-only). Used to simulate event
  /// sequences the fake's connection model doesn't produce on its own
  /// (e.g. peripheral supersession: disconnect-then-reconnect under a
  /// new platform address).
  void emitPortEvent(BlueyPortEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// Test hook: inject a [PortPeerConnected] event as if the platform
  /// reported a new link. Does not mutate the fake's internal
  /// connection-state sets — it drives only the event stream, which is
  /// what the tie-break logic reacts to.
  void emitPeerConnected(
    NodeId nodeId,
    ConnectionRole role, {
    required BleAddress address,
    String? displayName,
  }) {
    if (!_events.isClosed) {
      _events.add(
        PortPeerConnected(
          nodeId: nodeId,
          role: role,
          address: address,
          displayName: displayName,
        ),
      );
    }
  }

  /// Test hook: record an inbound link so sendData to [nodeId] routes.
  void markConnectedAsPeripheralForTest(NodeId nodeId) {
    _connectedAsPeripheral.add(nodeId);
  }

  /// Test hook: inject inbound data as if [from] wrote to us.
  void emitPeerData(NodeId from, Uint8List data) {
    if (!_events.isClosed) {
      _events.add(PortPeerData(nodeId: from, data: data));
    }
  }

  /// Test hook: inject a [PortPeerDisconnected] event.
  void emitPeerDisconnected(NodeId nodeId, ConnectionRole role, String reason) {
    if (!_events.isClosed) {
      _events.add(
        PortPeerDisconnected(nodeId: nodeId, role: role, reason: reason),
      );
    }
  }

  /// Drive an error on the port event stream (test-only).
  void emitPortError(Object error, [StackTrace? stackTrace]) {
    if (!_events.isClosed) {
      _events.addError(error, stackTrace ?? StackTrace.current);
    }
  }

  /// Drive an error on the open scan stream (test-only). Mirrors the real
  /// port, which forwards scanner errors via `onError: controller.addError`.
  void emitScanError(Object error, [StackTrace? stackTrace]) {
    final controller = _scanController;
    if (controller != null && !controller.isClosed) {
      controller.addError(error, stackTrace ?? StackTrace.current);
    }
  }

  /// Test hook: drive an adapter-state transition. Updates the cached
  /// value and broadcasts on [bluetoothStateStream]. When transitioning
  /// to anything other than `on`, also resets advertising/scan state to
  /// mimic the real port's behavior (bluey's Server/Scanner are marked
  /// `invalidated` and the port's derived state goes to idle/stopped).
  void setBluetoothAdapterStateForTest(BluetoothAdapterState state) {
    _adapterState = state;
    if (state != BluetoothAdapterState.on) {
      setAdvertisingStateForTest(bluey.AdvertisingState.idle);
      setScanStateForTest(bluey.ScanState.stopped);
    }
    if (!_adapterStateController.isClosed) {
      _adapterStateController.add(state);
    }
  }

  /// Read-only view of central-role connections held by this fake.
  Set<NodeId> get connectedAsCentral => Set.unmodifiable(_connectedAsCentral);

  /// Read-only view of peripheral-role connections held by this fake.
  Set<NodeId> get connectedAsPeripheral =>
      Set.unmodifiable(_connectedAsPeripheral);

  /// Number of live physical links to [peer] — central and peripheral
  /// counted separately. This is the ground truth the production
  /// registry cannot see (COR3-29): a mutual connect that converged
  /// correctly shows exactly 1 here.
  int physicalLinkCountTo(NodeId peer) =>
      (_connectedAsCentral.contains(peer) ? 1 : 0) +
      (_connectedAsPeripheral.contains(peer) ? 1 : 0);

  @override
  Stream<BlueyPortEvent> get events => _events.stream;

  @override
  BluetoothAdapterState get bluetoothAdapterState => _adapterState;

  @override
  Stream<BluetoothAdapterState> get bluetoothStateStream =>
      _adapterStateController.stream;

  @override
  Future<void> startAdvertising({
    required ServiceUuid serviceUuid,
    required String displayName,
    required NodeId localNodeId,
  }) async {
    _advertisedServiceUuid = serviceUuid;
    _advertisedDisplayName = displayName;
    setAdvertisingStateForTest(bluey.AdvertisingState.advertising);
  }

  @override
  Future<void> stopAdvertising() async {
    setAdvertisingStateForTest(bluey.AdvertisingState.idle);
  }

  @override
  Future<void> ensureReady() async {}

  @override
  Future<List<DiscoveredPeer>> discoverPeers({
    required ServiceUuid serviceUuid,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    onDiscoverPeers?.call(this);
    if (discoveryLatency > Duration.zero) {
      await Future<void>.delayed(discoveryLatency);
    }
    return network
        .advertisingPeersFor(serviceUuid)
        .where((p) => p.localNodeId != localNodeId)
        .map((p) => DiscoveredPeer(nodeId: p.localNodeId))
        .toList();
  }

  @override
  Future<void> connect(NodeId target) async {
    if (connectFailureInjector?.call(target) ?? false) {
      _events.add(
        PortConnectFailed(nodeId: target, reason: 'test injected failure'),
      );
      throw StateError('connect failed for $target');
    }
    final remote = network.lookup(target);
    if (remote == null) {
      throw StateError('no fake port for $target');
    }
    _connectedAsCentral.add(target);
    remote._connectedAsPeripheral.add(localNodeId);
    // The fake uses each port's NodeId as its BLE address (as a string)
    // since there's no real address space — this matches
    // FakeBlueyNetwork.scanCandidatesFor and honours the real-bluey
    // invariant that clientId equals device.address per platform.
    _events.add(
      PortPeerConnected(
        nodeId: target,
        role: ConnectionRole.central,
        address: BleAddress(target.value),
        displayName: remote._advertisedDisplayName,
      ),
    );
    remote._events.add(
      PortPeerConnected(
        nodeId: localNodeId,
        role: ConnectionRole.peripheral,
        address: BleAddress(localNodeId.value),
        displayName: _advertisedDisplayName,
      ),
    );
  }

  /// Records every [disconnect] call (role-blind).
  final List<NodeId> disconnectCalls = [];

  /// Records every [disconnectRole] call as (nodeId, role).
  final List<(NodeId, ConnectionRole)> disconnectRoleCalls = [];

  @override
  Future<void> disconnect(NodeId nodeId) async {
    disconnectCalls.add(nodeId);
    final remote = network.lookup(nodeId);
    final wasCentral = _connectedAsCentral.remove(nodeId);
    final wasPeripheral = _connectedAsPeripheral.remove(nodeId);
    if (!wasCentral && !wasPeripheral) return;
    if (wasCentral) {
      _events.add(
        PortPeerDisconnected(
          nodeId: nodeId,
          role: ConnectionRole.central,
          reason: 'local request',
        ),
      );
      // Our central → remote's peripheral view of us
      if (remote != null && remote._connectedAsPeripheral.remove(localNodeId)) {
        if (!remote._events.isClosed) {
          remote._events.add(
            PortPeerDisconnected(
              nodeId: localNodeId,
              role: ConnectionRole.peripheral,
              reason: 'peer disconnected',
            ),
          );
        }
      }
    }
    if (wasPeripheral) {
      _events.add(
        PortPeerDisconnected(
          nodeId: nodeId,
          role: ConnectionRole.peripheral,
          reason: 'local request',
        ),
      );
      // Our peripheral → remote's central view of us
      if (remote != null && remote._connectedAsCentral.remove(localNodeId)) {
        if (!remote._events.isClosed) {
          remote._events.add(
            PortPeerDisconnected(
              nodeId: localNodeId,
              role: ConnectionRole.central,
              reason: 'peer disconnected',
            ),
          );
        }
      }
    }
  }

  /// Test hook: per-call chunk size returned by [chunkSizeFor]. Defaults
  /// to 200 (large enough that small payloads fit in one chunk).
  int chunkSize = 200;

  @override
  int chunkSizeFor(NodeId nodeId) => chunkSize;

  @override
  Stream<String> get diagnosticLog => const Stream.empty();

  @override
  Stream<String> get diagnosticEvents => const Stream.empty();

  /// Records every payload passed to [sendData].
  final List<Uint8List> sentData = [];

  /// Test hook: awaited at the START of every [sendData] call, before
  /// any delivery. Lets tests pause a chunked send mid-message.
  Future<void> Function(NodeId target, Uint8List data)? sendGate;

  @override
  Future<void> sendData(NodeId nodeId, Uint8List data) async {
    final gate = sendGate;
    if (gate != null) await gate(nodeId, data);
    sentData.add(data);
    final remote = network.lookup(nodeId);
    if (remote == null ||
        (!_connectedAsCentral.contains(nodeId) &&
            !_connectedAsPeripheral.contains(nodeId))) {
      throw StateError('no connection to $nodeId');
    }
    if (chunkDropInjector?.call(nodeId, data) ?? false) {
      // Silently drop — simulates a write-without-response that was
      // never delivered. Returns success to the sender (matching real
      // BLE behaviour: writes-without-response have no ACK).
      return;
    }
    if (!remote._events.isClosed) {
      remote._events.add(PortPeerData(nodeId: localNodeId, data: data));
    }
  }

  @override
  Stream<ScanCandidate> scanForCandidates({required ServiceUuid serviceUuid}) {
    scanForCandidatesCallCount++;
    setScanStateForTest(bluey.ScanState.scanning);
    // Closed in [stopScan] and [dispose].
    // ignore: close_sinks
    final controller = StreamController<ScanCandidate>.broadcast();
    _scanController = controller;
    void emitOnce() {
      for (final c in network.scanCandidatesFor(serviceUuid, localNodeId)) {
        if (!controller.isClosed) controller.add(c);
      }
    }

    // Initial seed (microtask-deferred so listeners attach first).
    // ignore: discarded_futures
    Future<void>.microtask(emitOnce);
    // Mimic real BLE: the scanner continuously surfaces advertisements
    // for as long as a peer is advertising. Without periodic re-emission
    // the fake would stop "seeing" peers after the initial seed, which
    // breaks scenarios that depend on rediscovery (e.g. a peer that was
    // disconnected but is still advertising).
    _scanRebroadcastTimer?.cancel();
    _scanRebroadcastTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => emitOnce(),
    );
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    stopScanCallCount++;
    setScanStateForTest(bluey.ScanState.stopped);
    _scanRebroadcastTimer?.cancel();
    _scanRebroadcastTimer = null;
    final c = _scanController;
    _scanController = null;
    if (c != null && !c.isClosed) await c.close();
  }

  @override
  Future<NodeId> connectAndIdentify(ScanCandidate candidate) async {
    connectAndIdentifyCallCount++;
    onConnectAndIdentify?.call(candidate);
    if (connectAndIdentifyDelay > Duration.zero) {
      await Future<void>.delayed(connectAndIdentifyDelay);
    }
    final injected = _connectAndIdentifyErrors.remove(candidate.address);
    if (injected != null) {
      throw injected;
    }
    if (notABlueyPeerInjector?.call(candidate.address) ?? false) {
      throw NotABlueyPeerException(candidate.address);
    }
    if (connectAndIdentifyFailureInjector?.call(candidate.address) ?? false) {
      // Non-StateError so AutoConnectPolicy treats it as a generic
      // transient failure (which should trigger exponential backoff)
      // rather than as the benign reentrancy-guard case.
      throw Exception('test injected connectAndIdentify failure');
    }
    final target = NodeId(candidate.address.value);
    await connect(target);
    return target;
  }

  @override
  Future<void> disconnectRole(NodeId nodeId, ConnectionRole role) async {
    disconnectRoleCalls.add((nodeId, role));
    // Tear down only the requested role on this side, mirroring the
    // remote's view of that role. The other role (if any) stays intact.
    final remote = network.lookup(nodeId);
    switch (role) {
      case ConnectionRole.central:
        if (!_connectedAsCentral.remove(nodeId)) return;
        remote?._connectedAsPeripheral.remove(localNodeId);
        _events.add(
          PortPeerDisconnected(
            nodeId: nodeId,
            role: ConnectionRole.central,
            reason: 'local request (role)',
          ),
        );
        if (remote != null && !remote._events.isClosed) {
          remote._events.add(
            PortPeerDisconnected(
              nodeId: localNodeId,
              role: ConnectionRole.peripheral,
              reason: 'peer disconnected (role)',
            ),
          );
        }
      case ConnectionRole.peripheral:
        // A peripheral has NO per-client disconnect API in bluey: it
        // cannot force an inbound central off (COR3-21 — this is exactly
        // why GSP2 rejection frames exist). So this tears down only the
        // LOCAL peripheral bookkeeping; it does NOT close or notify the
        // remote central, which stays physically connected until it
        // closes its own link (e.g. on receiving a rejection frame). The
        // remote's view is cleaned up if/when it closes its central role,
        // whose disconnect DOES propagate.
        if (!_connectedAsPeripheral.remove(nodeId)) return;
        _events.add(
          PortPeerDisconnected(
            nodeId: nodeId,
            role: ConnectionRole.peripheral,
            reason: 'local request (role)',
          ),
        );
    }
  }

  @override
  Future<void> dispose() async {
    network.unregister(localNodeId);
    _scanRebroadcastTimer?.cancel();
    _scanRebroadcastTimer = null;
    final c = _scanController;
    _scanController = null;
    if (c != null && !c.isClosed) await c.close();
    if (!_adapterStateController.isClosed) {
      await _adapterStateController.close();
    }
    if (!_advertisingStateChanges.isClosed) {
      await _advertisingStateChanges.close();
    }
    if (!_scanStateChanges.isClosed) {
      await _scanStateChanges.close();
    }
    if (!_events.isClosed) {
      await _events.close();
    }
  }
}
