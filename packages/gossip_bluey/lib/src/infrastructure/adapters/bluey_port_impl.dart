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

/// A central-role link: we initiated, the peer is the GATT server.
///
/// Carries a unique [id] and owns its subscriptions so cleanup handlers
/// can verify they are tearing down THIS link and not a replacement that
/// arrived after a fast reconnect.
class _CentralLink {
  final int id;
  final bluey.PeerConnection peer;
  // Cancelled in _cleanupCentral, registration rollback, and dispose.
  // ignore: cancel_subscriptions
  StreamSubscription<Uint8List>? notifSub;
  // ignore: cancel_subscriptions
  StreamSubscription<bluey.ConnectionState>? stateSub;
  int? writePayload;

  _CentralLink(this.id, this.peer);
}

/// A peripheral-role link: the peer initiated, we are the GATT server.
class _PeripheralLink {
  final int id;
  final bluey.PeerClient peerClient;
  final int writePayload;

  /// Set on duplicate rejection. bluey has no per-client disconnect, so
  /// the physical link stays up; a rejected link is excluded from
  /// outbound sends but its inbound writes must still resolve.
  bool rejected = false;

  _PeripheralLink(this.id, this.peerClient, this.writePayload);

  bluey.ClientAddress get clientAddress => peerClient.client.address;
}

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
    LogCallback? onLog,
  }) : _localNodeIdValue = localNodeId.value,
       _bluey = blueyInstance,
       _onLog = onLog {
    _adapterState = _mapBlueyState(_bluey.currentState);
    _stateSub = _bluey.stateStream.listen(
      (s) => _onBluetoothStateChanged(_mapBlueyState(s)),
      onError: _logStreamError('bluetooth adapter state'),
    );
  }

  /// Construct a [BlueyPortImpl] wrapping a freshly-created `Bluey`
  /// instance. Async because `Bluey.create()` awaits the first platform
  /// state event before returning — see I333 in the bluey backlog.
  ///
  /// Pass [blueyInstance] to inject a pre-built `Bluey` (test fakes,
  /// shared instance reuse). When omitted, a new one is constructed with
  /// the local node id as the bluey `ServerId`.
  ///
  /// [onLog] receives diagnostics for platform stream errors — without a
  /// handler those would surface as uncaught zone errors.
  static Future<BlueyPortImpl> create({
    required NodeId localNodeId,
    bluey.Bluey? blueyInstance,
    LogCallback? onLog,
  }) async {
    final instance =
        blueyInstance ??
        await bluey.Bluey.create(
          localIdentity: bluey.ServerId(localNodeId.value),
        );
    return BlueyPortImpl._(
      localNodeId: localNodeId,
      blueyInstance: instance,
      onLog: onLog,
    );
  }

  final bluey.Bluey _bluey;
  final LogCallback? _onLog;

  /// onError handler for platform stream subscriptions: logs instead of
  /// letting the error escape as an uncaught zone error (which would
  /// bypass the package's logging surface entirely).
  void Function(Object, StackTrace) _logStreamError(String context) =>
      (Object e, StackTrace st) =>
          _onLog?.call(LogLevel.error, '$context stream error', e, st);
  bluey.Server? _server;
  ServiceUuid? _serviceUuid;
  final String _localNodeIdValue;

  /// Monotonic id source for [_CentralLink]/[_PeripheralLink] identity.
  int _nextLinkId = 0;

  /// Central-role links — we initiated, peer is the GATT server.
  final Map<NodeId, _CentralLink> _centralLinks = {};

  /// Peripheral-role links — they initiated, we are the GATT server.
  /// Keyed by the central's real `ServerId` (now exposed by
  /// [bluey.PeerClient]).
  final Map<NodeId, _PeripheralLink> _peripheralLinks = {};

  /// Reverse lookup: platform client address → NodeId. Populated when
  /// `peerConnections` fires; used to resolve `disconnections` events
  /// and `writeRequests` (which carry [bluey.Client], not [bluey.PeerClient]).
  /// Keyed by [bluey.ClientAddress] — the same value bluey emits on
  /// `Server.disconnections`, fixing the I337 cross-stream identifier
  /// mismatch.
  ///
  /// Entries survive duplicate rejection: the physical link stays up
  /// (no per-client disconnect API) and its writes must keep resolving.
  final Map<bluey.ClientAddress, NodeId> _clientAddressToNodeId = {};

  /// Cached bluey.Device handles for scan emissions, keyed by address.
  /// Looked up by [connectAndIdentify].
  final Map<BleAddress, bluey.Device> _devicesByAddress = {};

  // Cancelled in [stopScan] and [dispose].
  // ignore: cancel_subscriptions
  StreamSubscription<bluey.ScanResult>? _scanSubscription;
  // Closed in [stopScan] and [dispose].
  // ignore: close_sinks
  StreamController<ScanCandidate>? _scanController;
  // ignore: cancel_subscriptions
  StreamSubscription<bluey.ScanState>? _scanStateSub;
  bluey.ScanState _scanState = bluey.ScanState.stopped;
  final StreamController<bluey.ScanState> _scanStateChanges =
      StreamController<bluey.ScanState>.broadcast();

  // ignore: cancel_subscriptions
  StreamSubscription<bluey.AdvertisingState>? _advertisingStateSub;
  bluey.AdvertisingState _advertisingState = bluey.AdvertisingState.idle;
  final StreamController<bluey.AdvertisingState> _advertisingStateChanges =
      StreamController<bluey.AdvertisingState>.broadcast();

  late final StreamSubscription<bluey.BluetoothState> _stateSub;
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

  @override
  BluetoothAdapterState get bluetoothAdapterState => _adapterState;

  @override
  Stream<BluetoothAdapterState> get bluetoothStateStream =>
      _bluey.stateStream.map(_mapBlueyState);

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
    // Idempotent for the facade — if we already hold a server (whether
    // confirmed-advertising or mid-starting), don't construct a second
    // one. The previous server would be orphaned otherwise.
    if (_server != null) return;
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
      // Seed the cached state from the server's current value, then
      // subscribe for subsequent transitions.
      _setAdvertisingState(server.advertisingState);
      _advertisingStateSub = server.advertisingStateChanges.listen(
        _setAdvertisingState,
        onError: _logStreamError('advertising state'),
      );

      await server.addService(GossipGattService.build(serviceUuid));

      final charUuid = GossipCharacteristicUuids.derive(
        serviceUuid,
      ).dataCharacteristic;

      _serverSubs.add(
        server.peerConnections.listen((peerClient) {
          // bluey now exposes the central's real ServerId via
          // PeerClient.serverId — no synthesis needed.
          final nodeId = NodeId(peerClient.serverId.value);
          final clientAddress = peerClient.client.address;
          final address = BleAddress(clientAddress.value);
          // A previous link for this peer (fast reconnect with a new
          // platform address) is superseded: drop its stale address
          // mapping so late disconnections for it resolve to nothing, and
          // report the old link as disconnected BEFORE announcing the new
          // one — otherwise ConnectionManager still holds the old handle
          // and duplicate-rejects the LIVE replacement link (COR3-5). A
          // rejected link was already reported as disconnected.
          final previous = _peripheralLinks[nodeId];
          if (previous != null && previous.clientAddress != clientAddress) {
            _clientAddressToNodeId.remove(previous.clientAddress);
            if (!previous.rejected) {
              _events.add(
                PortPeerDisconnected(
                  nodeId: nodeId,
                  role: ConnectionRole.peripheral,
                  reason: 'superseded by reconnect',
                ),
              );
            }
          }
          // Peripheral side has no Connection.maxWritePayload — only the
          // Client.mtu raw value. Convert to a write-payload limit here
          // so the value semantics stay uniform with the central path.
          // On iOS, Client.mtu is always the BLE-default 23 (bluey
          // limitation — see I325) which would compute to an overly
          // conservative 19-byte chunk; substitute the iOS fallback
          // directly so chunkSizeFor stays trivial.
          final clientMtu = peerClient.client.mtu;
          final isIosDefaultMtu =
              clientMtu == _bleDefaultMtu &&
              _bluey.capabilities.platformKind.name == 'ios';
          final writePayload = isIosDefaultMtu
              ? _iosFallbackChunkSize
              : clientMtu - 3 - _safetyMargin;
          _peripheralLinks[nodeId] = _PeripheralLink(
            _nextLinkId++,
            peerClient,
            writePayload,
          );
          _clientAddressToNodeId[clientAddress] = nodeId;
          _events.add(
            PortPeerConnected(
              nodeId: nodeId,
              role: ConnectionRole.peripheral,
              address: address,
            ),
          );
        }, onError: _logStreamError('server peerConnections')),
      );

      _serverSubs.add(
        server.disconnections.listen((clientAddress) {
          final nodeId = _clientAddressToNodeId[clientAddress];
          if (nodeId == null) return;
          final link = _peripheralLinks[nodeId];
          if (link == null || link.clientAddress != clientAddress) {
            // Stale event for a superseded link (the peer already
            // reconnected under a new address). Tearing down by NodeId
            // here would unregister the LIVE client. Drop only the old
            // address mapping.
            _clientAddressToNodeId.remove(clientAddress);
            return;
          }
          _clientAddressToNodeId.remove(clientAddress);
          _peripheralLinks.remove(nodeId);
          _events.add(
            PortPeerDisconnected(
              nodeId: nodeId,
              role: ConnectionRole.peripheral,
              reason: 'peer disconnected',
            ),
          );
        }, onError: _logStreamError('server disconnections')),
      );

      _serverSubs.add(
        server.writeRequests.listen((req) {
          if (req.characteristicId.toString().toLowerCase() !=
              charUuid.toLowerCase()) {
            return;
          }
          final senderNodeId = _clientAddressToNodeId[req.client.address];
          if (senderNodeId == null) {
            // Write arrived before the client identified itself via the
            // lifecycle heartbeat. Drop — gossip will resync once the
            // peer is properly registered.
            return;
          }
          _events.add(PortPeerData(nodeId: senderNodeId, data: req.value));
          if (req.responseNeeded) {
            // Guarded: a failed GATT response otherwise becomes an
            // unhandled zone error. The sender's write times out and the
            // frame is re-sent by gossip anti-entropy.
            unawaited(
              server
                  .respondToWrite(
                    req,
                    status: bluey.GattResponseStatus.success,
                  )
                  .catchError((Object _) {}),
            );
          }
        }, onError: _logStreamError('server writeRequests')),
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
      await _advertisingStateSub?.cancel();
      _advertisingStateSub = null;
      _setAdvertisingState(bluey.AdvertisingState.idle);
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
    // Symmetric with startAdvertising: tear down every server-side
    // reference so the next start does a clean full setup. Without this
    // the early-return guard in startAdvertising would skip the rebuild
    // on a stop-then-start cycle.
    final server = _server;
    _server = null;
    _serviceUuid = null;
    await Future.wait(_serverSubs.map((sub) => sub.cancel()));
    _serverSubs.clear();
    await _advertisingStateSub?.cancel();
    _advertisingStateSub = null;
    _setAdvertisingState(bluey.AdvertisingState.idle);
    if (server != null) {
      await server.stopAdvertising();
      await server.dispose();
    }
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
  ///
  /// If a live central link for [target] already exists (iOS address
  /// rotation can yield two scan candidates for one peer), the new
  /// physical connection is dropped and the established link kept.
  ///
  /// Rolls back on failure: a throw mid-registration must not leave a
  /// stranded live connection with no state watcher.
  Future<void> _registerCentralConnection(
    NodeId target,
    BleAddress address,
    bluey.PeerConnection peerConnection,
  ) async {
    final serviceUuid = _serviceUuid;
    if (serviceUuid == null) {
      await _disconnectQuietly(peerConnection);
      throw StateError(
        '_registerCentralConnection requires startAdvertising first',
      );
    }

    if (_centralLinks.containsKey(target)) {
      // Duplicate central connection for a live NodeId — keep the
      // established link, drop the newcomer. No events: the registered
      // link is unaffected.
      await _disconnectQuietly(peerConnection);
      return;
    }

    final link = _CentralLink(_nextLinkId++, peerConnection);
    _centralLinks[target] = link;
    try {
      // Query the platform-authoritative write payload limit. On Android
      // this reflects the cached negotiated MTU; on iOS it comes from
      // CBPeripheral.maximumWriteValueLength(for:). Either way the value
      // IS the largest single ATT write — no MTU-minus-3 arithmetic
      // needed on our side (I325). Best-effort: failure leaves the link
      // without a value and chunkSizeFor falls back to the BLE default.
      try {
        final limit = await peerConnection.connection.maxWritePayload(
          withResponse: false,
        );
        link.writePayload = limit.value;
      } catch (_) {
        // chunkSizeFor's default takes over.
      }

      final charUuid = GossipCharacteristicUuids.derive(
        serviceUuid,
      ).dataCharacteristic;
      // cache: true — connectAsPeer already ran a full service discovery
      // moments ago; re-discovering over the air costs ~10-30 ATT PDUs
      // per connect for an identical answer (WIRE4-23).
      final services = await peerConnection.services(cache: true);
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
          'connected peer $target does not host the gossip data '
          'characteristic',
        );
      }
      final dataChar = dataCharCandidates.first;
      link.notifSub = dataChar.notifications.listen((bytes) {
        _events.add(PortPeerData(nodeId: target, data: bytes));
      }, onError: _logStreamError('notifications from $target'));

      link.stateSub = peerConnection.connection.stateChanges.listen((state) {
        if (state == bluey.ConnectionState.disconnected) {
          // _cleanupCentral verifies this link is still the current one,
          // so a stale event from a superseded link is a no-op.
          _cleanupCentral(target, link, reason: 'connection dropped');
        }
      }, onError: _logStreamError('connection state for $target'));
    } catch (e) {
      // Roll back: remove the entry, cancel any subscriptions, and
      // physically disconnect so nothing is stranded.
      if (identical(_centralLinks[target], link)) {
        _centralLinks.remove(target);
      }
      unawaited(link.notifSub?.cancel());
      unawaited(link.stateSub?.cancel());
      await _disconnectQuietly(peerConnection);
      rethrow;
    }

    _events.add(
      PortPeerConnected(
        nodeId: target,
        role: ConnectionRole.central,
        address: address,
      ),
    );
  }

  /// Tears down [link]'s bookkeeping — only if it is still the current
  /// link for [target]. Late events from superseded links are no-ops.
  void _cleanupCentral(
    NodeId target,
    _CentralLink link, {
    required String reason,
  }) {
    if (!identical(_centralLinks[target], link)) return;
    _centralLinks.remove(target);
    unawaited(link.notifSub?.cancel());
    unawaited(link.stateSub?.cancel());
    _events.add(
      PortPeerDisconnected(
        nodeId: target,
        role: ConnectionRole.central,
        reason: reason,
      ),
    );
  }

  Future<void> _disconnectQuietly(bluey.PeerConnection connection) async {
    try {
      await connection.disconnect();
    } catch (_) {
      // Best-effort teardown of an unwanted connection.
    }
  }

  @override
  int chunkSizeFor(NodeId nodeId) {
    // Mirror sendData's link preference: central first, then a live
    // (non-rejected) peripheral link.
    final peripheral = _peripheralLinks[nodeId];
    final size =
        _centralLinks[nodeId]?.writePayload ??
        (peripheral != null && !peripheral.rejected
            ? peripheral.writePayload
            : null);
    if (size == null) return _defaultChunkSize;
    return size < _defaultChunkSize ? _defaultChunkSize : size;
  }

  @override
  Future<void> disconnect(NodeId nodeId) async {
    _requireAdapterEnabled(nodeId);
    final central = _centralLinks[nodeId];
    if (central != null) {
      try {
        await central.peer.disconnect();
      } finally {
        _cleanupCentral(nodeId, central, reason: 'local request');
      }
      return;
    }
    _rejectPeripheral(nodeId, reason: 'local request');
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

    final central = _centralLinks[nodeId];
    if (central != null) {
      final services = await central.peer.services(cache: true);
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

    // A rejected peripheral link is deliberately NOT excluded here: the
    // physical link is still up (bluey has no per-client disconnect), and
    // the GSP2 rejection re-send (WIRE4-9) must be able to reach the
    // still-connected central. Gossip cannot route here by accident — the
    // ConnectionManager's registry entry for a rejected peer is gone, so
    // ordinary sends to it fail at that layer.
    final peripheral = _peripheralLinks[nodeId];
    if (peripheral != null) {
      final server = _server;
      if (server == null) {
        throw StateError('no server — startAdvertising not called?');
      }
      await server.notifyTo(
        peripheral.peerClient.client,
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
    // Track the scanner's lifecycle state so [scanState] reflects
    // platform reality, not just "we called scan()". Seed from the
    // scanner's current value, then subscribe for subsequent transitions.
    _setScanState(scanner.state);
    _scanStateSub = scanner.stateChanges.listen(
      _setScanState,
      onError: _logStreamError('scan state'),
    );
    _scanSubscription = scanner
        .scan(services: [bluey.UUID(serviceUuid.value)])
        .listen(
          (result) {
            final address = BleAddress(result.device.address.value);
            _devicesByAddress[address] = result.device;
            if (!controller.isClosed) {
              controller.add(
                ScanCandidate(
                  address: address,
                  displayName: result.device.name,
                  rssi: result.rssi,
                  lastSeen: DateTime.now(),
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
    // Bluey I335 wires scan()'s controller with onCancel: () => stop(),
    // so cancelling _scanSubscription is what stops the platform scan.
    //
    // ALL field mutations happen synchronously before the first await:
    // scanForCandidates fires this via unawaited() right before starting
    // a new scan, and a post-await mutation would clobber the NEW scan's
    // subscriptions/state (leaking its state sub and force-setting
    // scanState to stopped while scanning).
    final sub = _scanSubscription;
    _scanSubscription = null;
    final controller = _scanController;
    _scanController = null;
    final stateSub = _scanStateSub;
    _scanStateSub = null;
    _setScanState(bluey.ScanState.stopped);
    await stateSub?.cancel();
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
    } catch (e) {
      // Surface transient GATT connect failures on the event stream so
      // failure accounting (metrics) sees them; the throw still reaches
      // the caller for backoff.
      if (!_events.isClosed) {
        _events.add(
          PortConnectFailed(
            nodeId: NodeId(candidate.address.value),
            reason: 'connectAsPeer failed: $e',
          ),
        );
      }
      rethrow;
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
        final central = _centralLinks[nodeId];
        if (central == null) return;
        try {
          await central.peer.disconnect();
        } finally {
          _cleanupCentral(nodeId, central, reason: 'local request (role)');
        }
      case ConnectionRole.peripheral:
        _rejectPeripheral(nodeId, reason: 'local request (role)');
    }
  }

  /// "Disconnects" a peripheral-role link as far as we are able to.
  ///
  /// bluey.Server has no per-client disconnect API: the physical link
  /// STAYS UP until the central side or the lifecycle heartbeat tears it
  /// down. Critically, the address→NodeId mapping and the link record
  /// are KEPT — destroying them while the link is up would silently drop
  /// every inbound write from this peer. In a simultaneous mesh connect
  /// both sides duplicate-reject their peripheral role and keep sending
  /// on their central link, so the peer's gossip arrives HERE; dropping
  /// the mapping black-holes 100% of traffic in both directions.
  ///
  /// The link is marked rejected so [chunkSizeFor] stops preferring it;
  /// [sendData] still serves it deliberately — the GSP2 rejection re-send
  /// (WIRE4-9) needs the physically-alive link.
  void _rejectPeripheral(NodeId nodeId, {required String reason}) {
    final link = _peripheralLinks[nodeId];
    if (link == null || link.rejected) return;
    link.rejected = true;
    _events.add(
      PortPeerDisconnected(
        nodeId: nodeId,
        role: ConnectionRole.peripheral,
        reason: reason,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final s in _serverSubs) {
      await s.cancel();
    }
    _serverSubs.clear();
    for (final link in _centralLinks.values) {
      await link.notifSub?.cancel();
      await link.stateSub?.cancel();
      try {
        await link.peer.disconnect();
      } catch (_) {
        // best-effort
      }
    }
    _centralLinks.clear();
    _peripheralLinks.clear();
    _clientAddressToNodeId.clear();
    await stopScan();
    _devicesByAddress.clear();
    await _server?.dispose();
    _server = null;
    _invalidateLiveState();
    await _stateSub.cancel();
    await _events.close();
    await _advertisingStateChanges.close();
    await _scanStateChanges.close();
  }

  void _onBluetoothStateChanged(BluetoothAdapterState state) {
    _adapterState = state;
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

  /// Update the cached advertising state and broadcast the transition to
  /// any subscribers of [advertisingStateStream]. The single mutation
  /// point for [_advertisingState] — both the bluey subscription callback
  /// and teardown paths (stopAdvertising, _invalidateLiveState, rollback)
  /// route through here so every transition reaches subscribers.
  void _setAdvertisingState(bluey.AdvertisingState s) {
    _advertisingState = s;
    if (!_advertisingStateChanges.isClosed) {
      _advertisingStateChanges.add(s);
    }
  }

  /// Symmetric counterpart for [_setAdvertisingState], for scan state.
  /// The single mutation point for [_scanState] — both the scanner
  /// subscription callback and teardown paths route through here.
  void _setScanState(bluey.ScanState s) {
    _scanState = s;
    if (!_scanStateChanges.isClosed) {
      _scanStateChanges.add(s);
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
    final centralPeers = _centralLinks.keys.toList();
    // Rejected peripheral links were already reported as disconnected;
    // only live ones get a PortPeerDisconnected below.
    final peripheralPeers = _peripheralLinks.entries
        .where((e) => !e.value.rejected)
        .map((e) => e.key)
        .toList();

    for (final link in _centralLinks.values) {
      unawaited(link.notifSub?.cancel());
      unawaited(link.stateSub?.cancel());
    }
    for (final sub in _serverSubs) {
      unawaited(sub.cancel());
    }
    _serverSubs.clear();
    unawaited(_scanSubscription?.cancel());
    _scanSubscription = null;
    unawaited(_scanStateSub?.cancel());
    _scanStateSub = null;
    _setScanState(bluey.ScanState.stopped);
    unawaited(_advertisingStateSub?.cancel());
    _advertisingStateSub = null;
    _setAdvertisingState(bluey.AdvertisingState.idle);
    if (_scanController != null && !_scanController!.isClosed) {
      unawaited(_scanController!.close());
    }
    _scanController = null;

    _centralLinks.clear();
    _peripheralLinks.clear();
    _clientAddressToNodeId.clear();
    _devicesByAddress.clear();
    _server = null;
    _serviceUuid = null;

    // Fire one PortPeerDisconnected per peer per role. ConnectionManager's
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
