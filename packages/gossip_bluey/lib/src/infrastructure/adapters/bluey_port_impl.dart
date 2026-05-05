import 'dart:async';
import 'dart:typed_data';

import 'package:bluey/bluey.dart' as bluey;
import 'package:gossip/gossip.dart';

import '../../domain/interfaces/bluey_port.dart';
// ignore: unused_import
import '../../domain/value_objects/ble_address.dart';
import '../../domain/value_objects/discovered_peer.dart';
import '../../domain/value_objects/gossip_characteristic_uuids.dart';
import '../../domain/value_objects/scan_candidate.dart';
import '../../domain/value_objects/service_uuid.dart';
import 'gossip_gatt_service.dart';

/// Real adapter that wraps bluey's `Bluey` instance, satisfying
/// [BlueyPort].
///
/// Constructs a fresh `Bluey` instance with the local `ServerId` baked
/// in (via `Bluey(localIdentity: ...)`). bluey threads that identity
/// into both the GATT server (so other peers learn it via the lifecycle
/// control characteristic) and the lifecycle heartbeat (so the
/// peripheral side learns the central's `ServerId` from `PeerClient`).
class BlueyPortImpl implements BlueyPort {
  BlueyPortImpl({required NodeId localNodeId, bluey.Bluey? blueyInstance})
    : _localNodeIdValue = localNodeId.value,
      _bluey =
          blueyInstance ??
          bluey.Bluey(localIdentity: bluey.ServerId(localNodeId.value));

  final bluey.Bluey _bluey;
  bluey.Server? _server;
  ServiceUuid? _serviceUuid;
  final String _localNodeIdValue;

  /// Central-role connections — we initiated, peer is the GATT server.
  final Map<NodeId, bluey.PeerConnection> _centralConnections = {};
  final Map<NodeId, StreamSubscription<Uint8List>> _centralNotifSubs = {};
  final Map<NodeId, StreamSubscription<bluey.ConnectionState>>
  _centralStateSubs = {};

  /// Peripheral-role peer clients — they initiated, we are the GATT
  /// server. Keyed by the central's real `ServerId` (now exposed by
  /// [bluey.PeerClient]).
  final Map<NodeId, bluey.PeerClient> _peripheralClients = {};

  /// Reverse lookup: platform client id → NodeId. Populated when
  /// `peerConnections` fires; used to resolve `disconnections` events
  /// and `writeRequests` (which carry [bluey.Client], not [bluey.PeerClient]).
  final Map<String, NodeId> _clientIdToNodeId = {};

  /// Negotiated MTU per peer. Populated in [connect] (central role,
  /// after `requestMtu`) and in `peerConnections` (peripheral role,
  /// from `client.mtu`). Used by [chunkSizeFor].
  final Map<NodeId, int> _mtuByNode = {};

  /// Default ATT payload when MTU is unknown (BLE 4.0 default MTU 23
  /// minus 3-byte ATT header).
  static const int _defaultChunkSize = 20;

  /// Safety margin subtracted from the ATT payload to leave room for
  /// transient platform overhead (e.g. opcode encoding edge cases).
  static const int _safetyMargin = 1;

  final StreamController<BlueyPortEvent> _events =
      StreamController<BlueyPortEvent>.broadcast();
  final List<StreamSubscription<dynamic>> _serverSubs = [];

  @override
  Stream<BlueyPortEvent> get events => _events.stream;

  @override
  Stream<String> get diagnosticLog => _bluey.logEvents.map((e) {
    final levelStr = e.level.name.toUpperCase().padRight(5);
    final dataStr = e.data.isEmpty
        ? ''
        : ' ${e.data.entries.map((kv) => '${kv.key}=${kv.value}').join(' ')}';
    final codeStr = e.errorCode != null ? ' (${e.errorCode})' : '';
    return '[$levelStr] ${e.context}: ${e.message}$dataStr$codeStr';
  });

  @override
  Stream<String> get diagnosticEvents =>
      _bluey.events.map((e) => e.toString());

  @override
  Future<void> startAdvertising({
    required ServiceUuid serviceUuid,
    required String displayName,
    required NodeId localNodeId,
  }) async {
    if (localNodeId.value != _localNodeIdValue) {
      throw ArgumentError.value(
        localNodeId,
        'localNodeId',
        'must match the NodeId passed to BlueyPortImpl constructor '
            '(got ${localNodeId.value}, expected $_localNodeIdValue)',
      );
    }
    _serviceUuid = serviceUuid;
    final server = _bluey.server();
    if (server == null) {
      throw StateError(
        'peripheral role not supported on this platform — '
        'gossip_bluey requires both central and peripheral roles',
      );
    }
    _server = server;
    await server.addService(GossipGattService.build(serviceUuid));

    final charUuid = GossipCharacteristicUuids.derive(
      serviceUuid,
    ).dataCharacteristic;

    _serverSubs.add(
      server.peerConnections.listen((peerClient) {
        // bluey now exposes the central's real ServerId via
        // PeerClient.serverId — no synthesis needed.
        final nodeId = NodeId(peerClient.serverId.value);
        _peripheralClients[nodeId] = peerClient;
        _clientIdToNodeId[peerClient.client.id.toString()] = nodeId;
        _mtuByNode[nodeId] = peerClient.client.mtu;
        _events.add(
          PortPeerConnected(nodeId: nodeId, role: ConnectionRole.peripheral),
        );
      }),
    );

    _serverSubs.add(
      server.disconnections.listen((clientId) {
        final nodeId = _clientIdToNodeId.remove(clientId);
        if (nodeId != null) {
          _peripheralClients.remove(nodeId);
          _mtuByNode.remove(nodeId);
          _events.add(
            PortPeerDisconnected(nodeId: nodeId, reason: 'peer disconnected'),
          );
        }
      }),
    );

    _serverSubs.add(
      server.writeRequests.listen((req) {
        if (req.characteristicId.toString().toLowerCase() !=
            charUuid.toLowerCase()) {
          return;
        }
        final senderNodeId = _clientIdToNodeId[req.client.id.toString()];
        if (senderNodeId == null) {
          // Write arrived before the client identified itself via the
          // lifecycle heartbeat. Drop — gossip will resync once the
          // peer is properly registered.
          return;
        }
        _events.add(PortPeerData(nodeId: senderNodeId, data: req.value));
        if (req.responseNeeded) {
          unawaited(
            server.respondToWrite(
              req,
              status: bluey.GattResponseStatus.success,
            ),
          );
        }
      }),
    );

    await server.startAdvertising(
      name: displayName,
      services: [bluey.UUID(serviceUuid.value)],
      peerDiscoverable: true,
    );
  }

  @override
  Future<void> stopAdvertising() async {
    await _server?.stopAdvertising();
  }

  @override
  Future<void> ensureReady() => _bluey.ensureReady();

  @override
  Future<List<DiscoveredPeer>> discoverPeers({
    required ServiceUuid serviceUuid,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final peers = await _bluey.discoverPeers(timeout: timeout);
    final out = <DiscoveredPeer>[];
    for (final p in peers) {
      final nodeId = NodeId(p.serverId.value);
      if (nodeId.value == _localNodeIdValue) continue;
      out.add(DiscoveredPeer(nodeId: nodeId));
    }
    return out;
  }

  @override
  Future<void> connect(NodeId target) async {
    final serviceUuid = _serviceUuid;
    if (serviceUuid == null) {
      throw StateError(
        'connect requires startAdvertising to have been called first',
      );
    }
    final blueyPeer = _bluey.peer(bluey.ServerId(target.value));
    final peerConnection = await blueyPeer.connect();
    await _registerCentralConnection(target, peerConnection);
  }

  /// Wire the central-role bookkeeping for [target] given an already-
  /// connected [peerConnection]. Negotiates MTU, subscribes to the
  /// gossip data characteristic for incoming notifications, watches for
  /// state-change disconnects, and emits PortPeerConnected.
  Future<void> _registerCentralConnection(
    NodeId target,
    bluey.PeerConnection peerConnection,
  ) async {
    final serviceUuid = _serviceUuid;
    if (serviceUuid == null) {
      throw StateError(
        '_registerCentralConnection requires startAdvertising first',
      );
    }
    _centralConnections[target] = peerConnection;

    // Negotiate the largest MTU the platform allows. Best-effort —
    // failure leaves us at the BLE-default 23 (chunkSizeFor falls back
    // to 20 in that case).
    final caps = _bluey.capabilities;
    try {
      final desired = bluey.Mtu(caps.maxMtu, capabilities: caps);
      final negotiated = await peerConnection.connection.requestMtu(desired);
      _mtuByNode[target] = negotiated.value;
    } catch (_) {
      // requestMtu failed — read whatever the connection has now.
      _mtuByNode[target] = peerConnection.connection.mtu.value;
    }

    final charUuid = GossipCharacteristicUuids.derive(
      serviceUuid,
    ).dataCharacteristic;
    final services = await peerConnection.services();
    final gossipService = services.firstWhere(
      (s) => s.uuid.toString().toLowerCase() == serviceUuid.value,
      orElse: () => throw StateError(
        'connected peer $target does not host the gossip service',
      ),
    );
    final dataCharCandidates = gossipService.characteristics().where(
      (c) => c.uuid.toString().toLowerCase() == charUuid.toLowerCase(),
    );
    if (dataCharCandidates.isEmpty) {
      throw StateError(
        'connected peer $target does not host the gossip data characteristic',
      );
    }
    final dataChar = dataCharCandidates.first;
    _centralNotifSubs[target] = dataChar.notifications.listen((bytes) {
      _events.add(PortPeerData(nodeId: target, data: bytes));
    });

    final raw = peerConnection.connection;
    _centralStateSubs[target] = raw.stateChanges.listen((state) {
      if (state == bluey.ConnectionState.disconnected &&
          _centralConnections.containsKey(target)) {
        _cleanupCentral(target, reason: 'connection dropped');
      }
    });

    _events.add(
      PortPeerConnected(nodeId: target, role: ConnectionRole.central),
    );
  }

  void _cleanupCentral(NodeId target, {required String reason}) {
    _centralConnections.remove(target);
    _mtuByNode.remove(target);
    final notifSub = _centralNotifSubs.remove(target);
    if (notifSub != null) unawaited(notifSub.cancel());
    final stateSub = _centralStateSubs.remove(target);
    if (stateSub != null) unawaited(stateSub.cancel());
    _events.add(PortPeerDisconnected(nodeId: target, reason: reason));
  }

  @override
  int chunkSizeFor(NodeId nodeId) {
    final mtu = _mtuByNode[nodeId];
    if (mtu == null) return _defaultChunkSize;
    // ATT payload = MTU - 3 (ATT header). Subtract a safety margin.
    final size = mtu - 3 - _safetyMargin;
    return size < _defaultChunkSize ? _defaultChunkSize : size;
  }

  @override
  Future<void> disconnect(NodeId nodeId) async {
    final central = _centralConnections[nodeId];
    if (central != null) {
      try {
        await central.disconnect();
      } finally {
        _cleanupCentral(nodeId, reason: 'local request');
      }
      return;
    }
    final peripheral = _peripheralClients.remove(nodeId);
    if (peripheral != null) {
      _clientIdToNodeId.remove(peripheral.client.id.toString());
      _mtuByNode.remove(nodeId);
      // bluey.Server has no per-client disconnect API. Drop our local
      // reference and emit the disconnect event; the actual link will
      // be torn down by the lifecycle heartbeat protocol or by the
      // central side.
      _events.add(
        PortPeerDisconnected(nodeId: nodeId, reason: 'local request'),
      );
    }
  }

  @override
  Future<void> sendData(NodeId nodeId, Uint8List data) async {
    final serviceUuid = _serviceUuid;
    if (serviceUuid == null) {
      throw StateError(
        'sendData requires startAdvertising to have been called first',
      );
    }
    final charUuid = GossipCharacteristicUuids.derive(
      serviceUuid,
    ).dataCharacteristic;

    final central = _centralConnections[nodeId];
    if (central != null) {
      final services = await central.services(cache: true);
      final gossipService = services.firstWhere(
        (s) => s.uuid.toString().toLowerCase() == serviceUuid.value,
        orElse: () => throw StateError('gossip service missing on $nodeId'),
      );
      final dataCharCandidates = gossipService.characteristics().where(
        (c) => c.uuid.toString().toLowerCase() == charUuid.toLowerCase(),
      );
      if (dataCharCandidates.isEmpty) {
        throw StateError('gossip data characteristic missing on $nodeId');
      }
      await dataCharCandidates.first.write(data, withResponse: false);
      return;
    }

    final peripheralClient = _peripheralClients[nodeId];
    if (peripheralClient != null) {
      final server = _server;
      if (server == null) {
        throw StateError('no server — startAdvertising not called?');
      }
      await server.notifyTo(
        peripheralClient.client,
        bluey.UUID(charUuid),
        data: data,
      );
      return;
    }

    throw StateError('no connection to $nodeId');
  }

  @override
  Stream<ScanCandidate> scanForCandidates({required ServiceUuid serviceUuid}) {
    throw UnimplementedError('implemented in task 6');
  }

  @override
  Future<void> stopScan() async {
    throw UnimplementedError('implemented in task 6');
  }

  @override
  Future<NodeId> connectAndIdentify(ScanCandidate candidate) async {
    throw UnimplementedError('implemented in task 7');
  }

  @override
  Future<void> disconnectRole(NodeId nodeId, ConnectionRole role) async {
    throw UnimplementedError('implemented in task 8');
  }

  @override
  Future<void> dispose() async {
    for (final s in _serverSubs) {
      await s.cancel();
    }
    _serverSubs.clear();
    for (final s in _centralNotifSubs.values) {
      await s.cancel();
    }
    _centralNotifSubs.clear();
    for (final s in _centralStateSubs.values) {
      await s.cancel();
    }
    _centralStateSubs.clear();
    for (final c in _centralConnections.values) {
      try {
        await c.disconnect();
      } catch (_) {
        // best-effort
      }
    }
    _centralConnections.clear();
    _peripheralClients.clear();
    _clientIdToNodeId.clear();
    _mtuByNode.clear();
    await _server?.dispose();
    _server = null;
    await _events.close();
  }
}
