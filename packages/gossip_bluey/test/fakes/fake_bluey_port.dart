import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/errors/not_a_bluey_peer_exception.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';
import 'package:gossip_bluey/src/domain/value_objects/discovered_peer.dart';
import 'package:gossip_bluey/src/domain/value_objects/scan_candidate.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';

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
      if (p._isAdvertising && p._advertisedServiceUuid == serviceUuid) {
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
      if (!p._isAdvertising) continue;
      if (p._advertisedServiceUuid != serviceUuid) continue;
      yield ScanCandidate(
        address: BleAddress(p.localNodeId.value),
        displayName: p._advertisedDisplayName,
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
  bool _isAdvertising = false;
  ServiceUuid? _advertisedServiceUuid;
  String? _advertisedDisplayName;
  final Set<NodeId> _connectedAsCentral = {};
  final Set<NodeId> _connectedAsPeripheral = {};

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

  /// Test hook: when the predicate returns true for an address, the
  /// next connectAndIdentify call for that address throws
  /// [NotABlueyPeerException].
  bool Function(BleAddress address)? notABlueyPeerInjector;

  StreamController<ScanCandidate>? _scanController;
  Timer? _scanRebroadcastTimer;

  /// Drive a scan emission for the open scan stream (test-only). Used
  /// to deliver candidates synchronously in tests without depending on
  /// network advertise state.
  void emitScanCandidate(ScanCandidate candidate) {
    _scanController?.add(candidate);
  }

  /// Read-only view of central-role connections held by this fake.
  Set<NodeId> get connectedAsCentral => Set.unmodifiable(_connectedAsCentral);

  /// Read-only view of peripheral-role connections held by this fake.
  Set<NodeId> get connectedAsPeripheral =>
      Set.unmodifiable(_connectedAsPeripheral);

  @override
  Stream<BlueyPortEvent> get events => _events.stream;

  @override
  Future<void> startAdvertising({
    required ServiceUuid serviceUuid,
    required String displayName,
    required NodeId localNodeId,
  }) async {
    _isAdvertising = true;
    _advertisedServiceUuid = serviceUuid;
    _advertisedDisplayName = displayName;
  }

  @override
  Future<void> stopAdvertising() async {
    _isAdvertising = false;
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
      _events.add(PortConnectFailed(
        nodeId: target,
        reason: 'test injected failure',
      ));
      throw StateError('connect failed for $target');
    }
    final remote = network.lookup(target);
    if (remote == null) {
      throw StateError('no fake port for $target');
    }
    _connectedAsCentral.add(target);
    remote._connectedAsPeripheral.add(localNodeId);
    _events.add(PortPeerConnected(
      nodeId: target,
      role: ConnectionRole.central,
      displayName: remote._advertisedDisplayName,
    ));
    remote._events.add(PortPeerConnected(
      nodeId: localNodeId,
      role: ConnectionRole.peripheral,
      displayName: _advertisedDisplayName,
    ));
  }

  @override
  Future<void> disconnect(NodeId nodeId) async {
    final remote = network.lookup(nodeId);
    final wasCentral = _connectedAsCentral.remove(nodeId);
    final wasPeripheral = _connectedAsPeripheral.remove(nodeId);
    if (!wasCentral && !wasPeripheral) return;
    if (wasCentral) {
      _events.add(PortPeerDisconnected(
        nodeId: nodeId,
        role: ConnectionRole.central,
        reason: 'local request',
      ));
      // Our central → remote's peripheral view of us
      if (remote != null && remote._connectedAsPeripheral.remove(localNodeId)) {
        if (!remote._events.isClosed) {
          remote._events.add(PortPeerDisconnected(
            nodeId: localNodeId,
            role: ConnectionRole.peripheral,
            reason: 'peer disconnected',
          ));
        }
      }
    }
    if (wasPeripheral) {
      _events.add(PortPeerDisconnected(
        nodeId: nodeId,
        role: ConnectionRole.peripheral,
        reason: 'local request',
      ));
      // Our peripheral → remote's central view of us
      if (remote != null && remote._connectedAsCentral.remove(localNodeId)) {
        if (!remote._events.isClosed) {
          remote._events.add(PortPeerDisconnected(
            nodeId: localNodeId,
            role: ConnectionRole.central,
            reason: 'peer disconnected',
          ));
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

  @override
  Future<void> sendData(NodeId nodeId, Uint8List data) async {
    final remote = network.lookup(nodeId);
    if (remote == null ||
        (!_connectedAsCentral.contains(nodeId) &&
            !_connectedAsPeripheral.contains(nodeId))) {
      throw StateError('no connection to $nodeId');
    }
    if (!remote._events.isClosed) {
      remote._events.add(PortPeerData(nodeId: localNodeId, data: data));
    }
  }

  @override
  Stream<ScanCandidate> scanForCandidates({required ServiceUuid serviceUuid}) {
    final controller = StreamController<ScanCandidate>.broadcast();
    _scanController = controller;
    void emitOnce() {
      for (final c in network.scanCandidatesFor(serviceUuid, localNodeId)) {
        if (!controller.isClosed) controller.add(c);
      }
    }
    // Initial seed (microtask-deferred so listeners attach first).
    Future<void>.microtask(emitOnce);
    // Mimic real BLE: the scanner continuously surfaces advertisements
    // for as long as a peer is advertising. Without periodic re-emission
    // the fake would stop "seeing" peers after the initial seed, which
    // breaks scenarios that depend on rediscovery (e.g. a peer that was
    // disconnected but is still advertising).
    _scanRebroadcastTimer?.cancel();
    _scanRebroadcastTimer =
        Timer.periodic(const Duration(milliseconds: 100), (_) => emitOnce());
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    _scanRebroadcastTimer?.cancel();
    _scanRebroadcastTimer = null;
    final c = _scanController;
    _scanController = null;
    if (c != null && !c.isClosed) await c.close();
  }

  @override
  Future<NodeId> connectAndIdentify(ScanCandidate candidate) async {
    onConnectAndIdentify?.call(candidate);
    if (connectAndIdentifyDelay > Duration.zero) {
      await Future<void>.delayed(connectAndIdentifyDelay);
    }
    if (notABlueyPeerInjector?.call(candidate.address) ?? false) {
      throw NotABlueyPeerException(candidate.address);
    }
    if (connectAndIdentifyFailureInjector?.call(candidate.address) ?? false) {
      throw StateError('test injected connectAndIdentify failure');
    }
    final target = NodeId(candidate.address.value);
    await connect(target);
    return target;
  }

  @override
  Future<void> disconnectRole(NodeId nodeId, ConnectionRole role) async {
    // Tear down only the requested role on this side, mirroring the
    // remote's view of that role. The other role (if any) stays intact.
    final remote = network.lookup(nodeId);
    switch (role) {
      case ConnectionRole.central:
        if (!_connectedAsCentral.remove(nodeId)) return;
        remote?._connectedAsPeripheral.remove(localNodeId);
        _events.add(PortPeerDisconnected(
          nodeId: nodeId,
          role: ConnectionRole.central,
          reason: 'local request (role)',
        ));
        if (remote != null && !remote._events.isClosed) {
          remote._events.add(PortPeerDisconnected(
            nodeId: localNodeId,
            role: ConnectionRole.peripheral,
            reason: 'peer disconnected (role)',
          ));
        }
      case ConnectionRole.peripheral:
        if (!_connectedAsPeripheral.remove(nodeId)) return;
        remote?._connectedAsCentral.remove(localNodeId);
        _events.add(PortPeerDisconnected(
          nodeId: nodeId,
          role: ConnectionRole.peripheral,
          reason: 'local request (role)',
        ));
        if (remote != null && !remote._events.isClosed) {
          remote._events.add(PortPeerDisconnected(
            nodeId: localNodeId,
            role: ConnectionRole.central,
            reason: 'peer disconnected (role)',
          ));
        }
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
    if (!_events.isClosed) {
      await _events.close();
    }
  }
}
