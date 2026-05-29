import 'dart:async';
import 'dart:typed_data';

import 'package:bluey/bluey.dart' as bluey;
import 'package:gossip/gossip.dart';

import '../../domain/errors/bluetooth_unavailable_exception.dart';
import '../../domain/errors/not_a_bluey_peer_exception.dart' as domain;
import '../../domain/interfaces/bluey_port.dart';
import '../../domain/value_objects/ble_address.dart';
import '../../domain/value_objects/bluetooth_adapter_state.dart';
import '../../domain/value_objects/discovered_peer.dart';
import '../../domain/value_objects/gossip_characteristic_uuids.dart';
import '../../domain/value_objects/scan_candidate.dart';
import '../../domain/value_objects/service_uuid.dart';
import 'gossip_gatt_service.dart';

/// Real adapter that wraps bluey's `Bluey` instance, satisfying
/// [BlueyPort].
///
/// Constructs a fresh `Bluey` instance with the local `ServerId` baked
/// in (via `Bluey.create(localIdentity: ...)`). bluey threads that
/// identity into both the GATT server (so other peers learn it via the
/// lifecycle control characteristic) and the lifecycle heartbeat (so the
/// peripheral side learns the central's `ServerId` from `PeerClient`).
class BlueyPortImpl implements BlueyPort {
  BlueyPortImpl._({
    required NodeId localNodeId,
    required bluey.Bluey blueyInstance,
  }) : _localNodeIdValue = localNodeId.value,
       _bluey = blueyInstance {
    _adapterState = _mapBlueyState(_bluey.currentState);
    _adapterStateController = StreamController<BluetoothAdapterState>.broadcast(
      onListen: () {
        // Replay the current value to new subscribers so they don't have
        // to wait for the next transition to learn the state.
        if (!_adapterStateController.isClosed) {
          _adapterStateController.add(_adapterState);
        }
      },
    );
    _stateSub = _bluey.stateStream.listen(
      (s) => _onBluetoothStateChanged(_mapBlueyState(s)),
    );
  }

  /// Construct a [BlueyPortImpl] wrapping a freshly-created `Bluey`
  /// instance. Async because `Bluey.create()` awaits the first platform
  /// state event before returning — see I333 in the bluey backlog.
  ///
  /// Pass [blueyInstance] to inject a pre-built `Bluey` (test fakes,
  /// shared instance reuse). When omitted, a new one is constructed with
  /// the local node id as the bluey `ServerId`.
  static Future<BlueyPortImpl> create({
    required NodeId localNodeId,
    bluey.Bluey? blueyInstance,
  }) async {
    final instance =
        blueyInstance ??
        await bluey.Bluey.create(
          localIdentity: bluey.ServerId(localNodeId.value),
        );
    return BlueyPortImpl._(localNodeId: localNodeId, blueyInstance: instance);
  }

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

  /// Largest single ATT write payload per peer. Populated by
  /// [_registerCentralConnection] (central role, via
  /// `Connection.maxWritePayload`) and by `peerConnections`
  /// (peripheral role, from `Client.mtu` minus ATT overhead). Used by
  /// [chunkSizeFor]. Value semantics are uniform on both sides: this
  /// IS the max chunk size; no further arithmetic at the read site.
  final Map<NodeId, int> _writePayloadByNode = {};

  /// Cached bluey.Device handles for scan emissions, keyed by address.
  /// Looked up by [connectAndIdentify].
  final Map<BleAddress, bluey.Device> _devicesByAddress = {};

  // Cancelled in [stopScan] and [dispose].
  // ignore: cancel_subscriptions
  StreamSubscription<bluey.ScanResult>? _scanSubscription;
  // Closed in [stopScan] and [dispose].
  // ignore: close_sinks
  StreamController<ScanCandidate>? _scanController;
  // Held so [stopScan] can call scanner.stop() — bluey doesn't propagate
  // controller cancellation to the platform, so without this the radio
  // keeps scanning even after our subscription is torn down.
  bluey.Scanner? _scanner;

  late final StreamSubscription<bluey.BluetoothState> _stateSub;
  late final StreamController<BluetoothAdapterState> _adapterStateController;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;

  /// Set by `_onBluetoothStateChanged` when the adapter transitions away
  /// from on. Read by `_requireAdapterEnabled` (Task 7 gate) to short-circuit
  /// operations with `BluetoothUnavailableException`.
  bool _adapterDisabled = false;

  /// Set on the first call to [dispose] to make subsequent calls no-ops.
  /// Prevents `_invalidateLiveState` from re-emitting `PortPeerDisconnected`
  /// events on a closed `_events` controller.
  bool _disposed = false;

  /// Default ATT payload when MTU is unknown (BLE 4.0 default MTU 23
  /// minus 3-byte ATT header).
  static const int _defaultChunkSize = 20;

  /// Reason emitted on `PortPeerDisconnected` events fired by
  /// `_invalidateLiveState` when the adapter goes off or the port is
  /// disposed.
  static const String _adapterUnavailableReason =
      'bluetooth adapter unavailable';

  /// Safety margin subtracted from the ATT payload to leave room for
  /// transient platform overhead (e.g. opcode encoding edge cases).
  static const int _safetyMargin = 1;

  /// BLE-default ATT MTU. iOS reports this from Connection.mtu even
  /// after auto-negotiating higher; we use it as a sentinel for "MTU
  /// unknown on iOS" and fall back to [_iosFallbackChunkSize].
  static const int _bleDefaultMtu = 23;

  /// Conservative fallback chunk size on iOS when the platform-
  /// negotiated MTU isn't surfaced through bluey's Connection.mtu
  /// (always 23 on iOS — see bluey backlog I325). 100 bytes is well
  /// below the typical iOS maximumWriteValueLength minimum (158+ on
  /// iOS 13+) and is safe on all known hardware.
  ///
  /// TODO(I325): once bluey exposes Connection.maxWritePayload, drop
  /// this branch and use the new API directly.
  static const int _iosFallbackChunkSize = 100;

  final StreamController<BlueyPortEvent> _events =
      StreamController<BlueyPortEvent>.broadcast();
  final List<StreamSubscription<dynamic>> _serverSubs = [];

  @override
  Stream<BlueyPortEvent> get events => _events.stream;

  @override
  BluetoothAdapterState get bluetoothAdapterState => _adapterState;

  @override
  Stream<BluetoothAdapterState> get bluetoothStateStream =>
      _adapterStateController.stream;

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
  Stream<String> get diagnosticEvents => _bluey.events.map((e) => e.toString());

  @override
  Future<void> startAdvertising({
    required ServiceUuid serviceUuid,
    required String displayName,
    required NodeId localNodeId,
  }) async {
    _requireAdapterEnabled();
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
      _serviceUuid = null;
      throw StateError(
        'peripheral role not supported on this platform — '
        'gossip_bluey requires both central and peripheral roles',
      );
    }
    _server = server;

    try {
      await server.addService(GossipGattService.build(serviceUuid));

      final charUuid = GossipCharacteristicUuids.derive(
        serviceUuid,
      ).dataCharacteristic;

      _serverSubs.add(
        server.peerConnections.listen((peerClient) {
          // bluey now exposes the central's real ServerId via
          // PeerClient.serverId — no synthesis needed.
          final nodeId = NodeId(peerClient.serverId.value);
          final clientIdString = peerClient.client.id.toString();
          final address = BleAddress(clientIdString);
          _peripheralClients[nodeId] = peerClient;
          _clientIdToNodeId[clientIdString] = nodeId;
          // Peripheral side has no Connection.maxWritePayload — only the
          // Client.mtu raw value. Convert to a write-payload limit here
          // so the map's value semantics stay uniform with the central
          // path. On iOS, Client.mtu is always the BLE-default 23
          // (bluey limitation — see I325) which would compute to an
          // overly conservative 19-byte chunk; substitute the iOS
          // fallback directly so chunkSizeFor stays trivial.
          final clientMtu = peerClient.client.mtu;
          final isIosDefaultMtu =
              clientMtu == _bleDefaultMtu &&
              _bluey.capabilities.platformKind.name == 'ios';
          _writePayloadByNode[nodeId] = isIosDefaultMtu
              ? _iosFallbackChunkSize
              : clientMtu - 3 - _safetyMargin;
          _events.add(
            PortPeerConnected(
              nodeId: nodeId,
              role: ConnectionRole.peripheral,
              address: address,
            ),
          );
        }),
      );

      _serverSubs.add(
        server.disconnections.listen((clientId) {
          final nodeId = _clientIdToNodeId.remove(clientId);
          if (nodeId != null) {
            _peripheralClients.remove(nodeId);
            _writePayloadByNode.remove(nodeId);
            _events.add(
              PortPeerDisconnected(
                nodeId: nodeId,
                role: ConnectionRole.peripheral,
                reason: 'peer disconnected',
              ),
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
    } on Exception catch (e, st) {
      // Roll back partial setup so a retry starts clean. Cancel any
      // subscriptions we managed to register before the throw, drop the
      // stale server reference, clear _serviceUuid.
      await Future.wait(_serverSubs.map((sub) => sub.cancel()));
      _serverSubs.clear();
      _server = null;
      _serviceUuid = null;
      // The catch is broad on purpose — bluey doesn't yet differentiate
      // state-related failures from other lifecycle errors. Once bluey's
      // backlog I333 lands typed exceptions, narrow this to
      // `on bluey.BluetoothUnavailableException catch (e)`.
      Error.throwWithStackTrace(BluetoothUnavailableException(cause: e), st);
    }
  }

  @override
  Future<void> stopAdvertising() async {
    // Pure teardown — safe to call when the adapter is disabled (the
    // underlying server has already been cleared by _invalidateLiveState).
    await _server?.stopAdvertising();
  }

  @override
  Future<void> ensureReady() async {
    _requireAdapterEnabled();
    // Bluey.ensureReady() was removed in I333 — bluey's factory methods
    // (server, connect, scanner) now pre-check adapter state and throw
    // typed exceptions. We keep this method on the BlueyPort interface
    // so the example app can probe between permission grant and the
    // first lifecycle call; throw our own typed exception when the
    // adapter isn't on.
    final state = _mapBlueyState(_bluey.currentState);
    if (state != BluetoothAdapterState.on) {
      throw const BluetoothUnavailableException();
    }
  }

  @override
  Future<List<DiscoveredPeer>> discoverPeers({
    required ServiceUuid serviceUuid,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _requireAdapterEnabled();
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
    _requireAdapterEnabled(target);
    final serviceUuid = _serviceUuid;
    if (serviceUuid == null) {
      throw StateError(
        'connect requires startAdvertising to have been called first',
      );
    }
    final blueyPeer = _bluey.peer(bluey.ServerId(target.value));
    final peerConnection = await blueyPeer.connect();
    // connect(NodeId) is the legacy/test-only path. The platform
    // Device.address for a NodeId-initiated connection is not accessible
    // here; fall back to using the NodeId as the address. Production
    // code goes through connectAndIdentify, which always has the real
    // address from the originating ScanCandidate.
    await _registerCentralConnection(
      target,
      BleAddress(target.value),
      peerConnection,
    );
  }

  /// Wire the central-role bookkeeping for [target] given an already-
  /// connected [peerConnection]. Negotiates MTU, subscribes to the
  /// gossip data characteristic for incoming notifications, watches for
  /// state-change disconnects, and emits PortPeerConnected.
  Future<void> _registerCentralConnection(
    NodeId target,
    BleAddress address,
    bluey.PeerConnection peerConnection,
  ) async {
    final serviceUuid = _serviceUuid;
    if (serviceUuid == null) {
      throw StateError(
        '_registerCentralConnection requires startAdvertising first',
      );
    }
    _centralConnections[target] = peerConnection;

    // Query the platform-authoritative write payload limit. On Android
    // this reflects the cached negotiated MTU; on iOS it comes from
    // CBPeripheral.maximumWriteValueLength(for:). Either way the value
    // IS the largest single ATT write — no MTU-minus-3 arithmetic needed
    // on our side (I325). Best-effort: failure leaves us with no entry
    // and chunkSizeFor falls back to the BLE-safe default.
    try {
      final limit = await peerConnection.connection.maxWritePayload(
        withResponse: false,
      );
      _writePayloadByNode[target] = limit.value;
    } catch (_) {
      // Leave _writePayloadByNode unset — chunkSizeFor's default takes over.
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
      PortPeerConnected(
        nodeId: target,
        role: ConnectionRole.central,
        address: address,
      ),
    );
  }

  void _cleanupCentral(NodeId target, {required String reason}) {
    _centralConnections.remove(target);
    _writePayloadByNode.remove(target);
    final notifSub = _centralNotifSubs.remove(target);
    if (notifSub != null) unawaited(notifSub.cancel());
    final stateSub = _centralStateSubs.remove(target);
    if (stateSub != null) unawaited(stateSub.cancel());
    _events.add(
      PortPeerDisconnected(
        nodeId: target,
        role: ConnectionRole.central,
        reason: reason,
      ),
    );
  }

  @override
  int chunkSizeFor(NodeId nodeId) {
    final size = _writePayloadByNode[nodeId];
    if (size == null) return _defaultChunkSize;
    return size < _defaultChunkSize ? _defaultChunkSize : size;
  }

  @override
  Future<void> disconnect(NodeId nodeId) async {
    _requireAdapterEnabled(nodeId);
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
      _writePayloadByNode.remove(nodeId);
      // bluey.Server has no per-client disconnect API. Drop our local
      // reference and emit the disconnect event; the actual link will
      // be torn down by the lifecycle heartbeat protocol or by the
      // central side.
      _events.add(
        PortPeerDisconnected(
          nodeId: nodeId,
          role: ConnectionRole.peripheral,
          reason: 'local request',
        ),
      );
    }
  }

  @override
  Future<void> sendData(NodeId nodeId, Uint8List data) async {
    _requireAdapterEnabled(nodeId);
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
    _requireAdapterEnabled();
    // If a previous scan is still open, tear it down first.
    final previous = _scanController;
    if (previous != null) {
      unawaited(stopScan());
    }
    // Closed in [stopScan] and [dispose] (also via onCancel below).
    // ignore: close_sinks
    final controller = StreamController<ScanCandidate>.broadcast(
      onCancel: () => unawaited(stopScan()),
    );
    _scanController = controller;
    final scanner = _bluey.scanner();
    _scanner = scanner;
    _scanSubscription = scanner
        .scan(services: [bluey.UUID(serviceUuid.value)])
        .listen(
          (result) {
            final address = BleAddress(result.device.address);
            _devicesByAddress[address] = result.device;
            if (!controller.isClosed) {
              controller.add(
                ScanCandidate(
                  address: address,
                  displayName: result.device.name,
                ),
              );
            }
          },
          onError: controller.addError,
          onDone: () => unawaited(stopScan()),
        );
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    // Pure teardown — safe to call when the adapter is disabled (the
    // underlying scan has already been cleared by _invalidateLiveState).
    final scanner = _scanner;
    _scanner = null;
    final sub = _scanSubscription;
    _scanSubscription = null;
    final controller = _scanController;
    _scanController = null;
    // Tell bluey to actually stop the platform scan. Cancelling our
    // subscription on the controller stream does not propagate to the
    // platform — only scanner.stop() does.
    if (scanner != null) {
      try {
        await scanner.stop();
      } catch (_) {
        // Best-effort; the adapter may have already torn the scan down.
      }
    }
    await sub?.cancel();
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }

  @override
  Future<NodeId> connectAndIdentify(ScanCandidate candidate) async {
    _requireAdapterEnabled();
    final device = _devicesByAddress[candidate.address];
    if (device == null) {
      throw StateError(
        'no scan-emitted device for ${candidate.address} — '
        "did the candidate come from this port's scanForCandidates stream?",
      );
    }
    final bluey.PeerConnection peerConn;
    try {
      peerConn = await _bluey.connectAsPeer(device);
    } on bluey.NotABlueyPeerException {
      throw domain.NotABlueyPeerException(candidate.address);
    }
    final nodeId = NodeId(peerConn.serverId.value);
    await _registerCentralConnection(nodeId, candidate.address, peerConn);
    return nodeId;
  }

  @override
  Future<void> disconnectRole(NodeId nodeId, ConnectionRole role) async {
    _requireAdapterEnabled(nodeId);
    switch (role) {
      case ConnectionRole.central:
        final central = _centralConnections[nodeId];
        if (central == null) return;
        try {
          await central.disconnect();
        } finally {
          _cleanupCentral(nodeId, reason: 'local request (role)');
        }
      case ConnectionRole.peripheral:
        final peripheral = _peripheralClients.remove(nodeId);
        if (peripheral == null) return;
        _clientIdToNodeId.remove(peripheral.client.id.toString());
        _writePayloadByNode.remove(nodeId);
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
    if (_disposed) return;
    _disposed = true;
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
    _writePayloadByNode.clear();
    await stopScan();
    _devicesByAddress.clear();
    await _server?.dispose();
    _server = null;
    _invalidateLiveState();
    await _stateSub.cancel();
    if (!_adapterStateController.isClosed) {
      await _adapterStateController.close();
    }
    await _events.close();
  }

  void _onBluetoothStateChanged(BluetoothAdapterState state) {
    _adapterState = state;
    if (!_adapterStateController.isClosed) {
      _adapterStateController.add(state);
    }
    final isOn = state == BluetoothAdapterState.on;
    if (!isOn && !_adapterDisabled) {
      _adapterDisabled = true;
      _invalidateLiveState();
    } else if (isOn && _adapterDisabled) {
      _adapterDisabled = false;
      // No auto-reinit — consumer must call startAdvertising again.
    }
  }

  static BluetoothAdapterState _mapBlueyState(bluey.BluetoothState s) {
    switch (s) {
      case bluey.BluetoothState.on:
        return BluetoothAdapterState.on;
      case bluey.BluetoothState.off:
        return BluetoothAdapterState.off;
      case bluey.BluetoothState.unauthorized:
        return BluetoothAdapterState.unauthorized;
      case bluey.BluetoothState.unsupported:
        return BluetoothAdapterState.unsupported;
      case bluey.BluetoothState.unknown:
        return BluetoothAdapterState.unknown;
    }
  }

  void _requireAdapterEnabled([NodeId? nodeId]) {
    if (_adapterDisabled) {
      throw BluetoothUnavailableException(nodeId: nodeId);
    }
  }

  /// Drop every live reference to platform objects, cancel every
  /// subscription, fire PortPeerDisconnected for every active peer.
  /// Idempotent. Called on adapter-off and on dispose.
  void _invalidateLiveState() {
    final centralPeers = _centralConnections.keys.toList();
    final peripheralPeers = _peripheralClients.keys.toList();

    for (final sub in _centralNotifSubs.values) {
      unawaited(sub.cancel());
    }
    _centralNotifSubs.clear();
    for (final sub in _centralStateSubs.values) {
      unawaited(sub.cancel());
    }
    _centralStateSubs.clear();
    for (final sub in _serverSubs) {
      unawaited(sub.cancel());
    }
    _serverSubs.clear();
    unawaited(_scanSubscription?.cancel());
    _scanSubscription = null;
    if (_scanController != null && !_scanController!.isClosed) {
      unawaited(_scanController!.close());
    }
    _scanController = null;
    _scanner = null;

    _centralConnections.clear();
    _peripheralClients.clear();
    _clientIdToNodeId.clear();
    _writePayloadByNode.clear();
    _devicesByAddress.clear();
    _server = null;
    _serviceUuid = null;

    // Fire one PortPeerDisconnected per peer per role. ConnectionService's
    // existing handler removes registry entries and emits PeerClosed.
    for (final nodeId in centralPeers) {
      _events.add(
        PortPeerDisconnected(
          nodeId: nodeId,
          role: ConnectionRole.central,
          reason: _adapterUnavailableReason,
        ),
      );
    }
    final centralPeerSet = centralPeers.toSet();
    for (final nodeId in peripheralPeers) {
      // Avoid double-firing for cross-role-tracked peers (the central
      // event above already covered them).
      if (centralPeerSet.contains(nodeId)) continue;
      _events.add(
        PortPeerDisconnected(
          nodeId: nodeId,
          role: ConnectionRole.peripheral,
          reason: _adapterUnavailableReason,
        ),
      );
    }
  }
}
