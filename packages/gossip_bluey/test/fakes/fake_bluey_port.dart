import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';
import 'package:gossip_bluey/src/domain/value_objects/discovered_peer.dart';
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
    _events.add(PortPeerDisconnected(nodeId: nodeId, reason: 'local request'));
    remote?._connectedAsCentral.remove(localNodeId);
    remote?._connectedAsPeripheral.remove(localNodeId);
    if (remote != null && !remote._events.isClosed) {
      remote._events.add(
        PortPeerDisconnected(nodeId: localNodeId, reason: 'peer disconnected'),
      );
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
  Future<void> dispose() async {
    network.unregister(localNodeId);
    if (!_events.isClosed) {
      await _events.close();
    }
  }
}
