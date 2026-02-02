import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluetooth_low_energy_platform_interface/bluetooth_low_energy_platform_interface.dart';

import '../../domain/ports/ble_port.dart';
import '../../domain/value_objects/device_id.dart';
import '../util/write_queue.dart';
import 'central_adapter.dart' show NusUuids, AdapterLogCallback;

/// Manages the Peripheral role: advertising and accepting connections.
class PeripheralAdapter {
  final PeripheralManager _peripheralManager;
  final WriteQueue _notifyQueue;
  final AdapterLogCallback? _onLog;

  final _eventController = StreamController<BleEvent>.broadcast();

  // Connected centrals
  final Map<String, Central> _connections = {};

  // Track which centrals have subscribed to notifications
  final Set<String> _subscribedCentrals = {};

  // Pending payloads for unsubscribed centrals
  final Map<String, List<Uint8List>> _pendingPayloads = {};

  // Our GATT service
  GATTService? _gattService;
  GATTCharacteristic? _txCharacteristic;
  GATTCharacteristic? _rxCharacteristic;

  // Subscriptions
  StreamSubscription? _stateSubscription;
  StreamSubscription? _connectionStateChangedSubscription;
  StreamSubscription? _writeRequestedSubscription;
  StreamSubscription? _notifyStateChangedSubscription;

  bool _isAdvertising = false;

  PeripheralAdapter({
    PeripheralManager? peripheralManager,
    WriteQueue? notifyQueue,
    AdapterLogCallback? onLog,
  }) : _peripheralManager = peripheralManager ?? PeripheralManager(),
       _notifyQueue = notifyQueue ?? WriteQueue(),
       _onLog = onLog {
    _setupSubscriptions();
  }

  Stream<BleEvent> get events => _eventController.stream;

  void _log(String message) {
    _onLog?.call('[Peripheral] $message');
  }

  void _setupSubscriptions() {
    _stateSubscription = _peripheralManager.stateChanged.listen((event) {
      _log('State changed: ${event.state}');
    });

    // connectionStateChanged is not supported on Darwin (iOS/macOS).
    // On those platforms, we detect connections via write requests and
    // notify state changes instead (see fallback handling in those methods).
    if (!Platform.isIOS && !Platform.isMacOS) {
      _connectionStateChangedSubscription = _peripheralManager
          .connectionStateChanged
          .listen(_onConnectionStateChanged);
    }

    _writeRequestedSubscription = _peripheralManager
        .characteristicWriteRequested
        .listen(_onWriteRequested);

    _notifyStateChangedSubscription = _peripheralManager
        .characteristicNotifyStateChanged
        .listen(_onNotifyStateChanged);
  }

  Future<void> startAdvertising(String displayName) async {
    if (_isAdvertising) return;

    final state = await _peripheralManager.getState();
    if (state != BluetoothLowEnergyState.on) {
      _log('Bluetooth not on, cannot advertise');
      return;
    }

    // Create GATT service
    _txCharacteristic = GATTCharacteristic.mutable(
      uuid: NusUuids.tx,
      properties: [
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.writeWithoutResponse,
      ],
      permissions: [GATTPermission.write],
      descriptors: [],
    );

    _rxCharacteristic = GATTCharacteristic.mutable(
      uuid: NusUuids.rx,
      properties: [
        GATTCharacteristicProperty.notify,
        GATTCharacteristicProperty.indicate,
      ],
      permissions: [GATTPermission.read],
      descriptors: [],
    );

    _gattService = GATTService(
      uuid: NusUuids.service,
      isPrimary: true,
      includedServices: [],
      characteristics: [_txCharacteristic!, _rxCharacteristic!],
    );

    await _peripheralManager.removeAllServices();
    await _peripheralManager.addService(_gattService!);

    final advertisement = Advertisement(
      name: displayName,
      serviceUUIDs: [NusUuids.service],
    );

    _log('Starting advertising as "$displayName"...');

    if (Platform.isAndroid) {
      unawaited(_peripheralManager.startAdvertising(advertisement));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      _isAdvertising = true;
    } else {
      await _peripheralManager.startAdvertising(advertisement);
      _isAdvertising = true;
    }

    _log('Advertising started');
  }

  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;

    _log('Stopping advertising...');
    await _peripheralManager.stopAdvertising();
    await _peripheralManager.removeAllServices();
    _gattService = null;
    _txCharacteristic = null;
    _rxCharacteristic = null;
    _isAdvertising = false;
    _log('Advertising stopped');
  }

  Future<void> send(DeviceId deviceId, Uint8List bytes) async {
    final centralId = deviceId.value;
    final central = _connections[centralId];

    if (central == null || _rxCharacteristic == null) {
      _log('Cannot send to $centralId: not connected');
      return;
    }

    if (!_subscribedCentrals.contains(centralId)) {
      _log('Central $centralId not subscribed, queueing payload');
      _pendingPayloads.putIfAbsent(centralId, () => []).add(bytes);
      return;
    }

    await _notifyQueue.enqueue(centralId, () async {
      await _peripheralManager.notifyCharacteristic(
        _rxCharacteristic!,
        value: bytes,
        centrals: [central],
      );
    });

    _log('Sent ${bytes.length} bytes to $centralId');
  }

  bool hasConnection(DeviceId deviceId) {
    return _connections.containsKey(deviceId.value);
  }

  Future<void> dispose() async {
    await stopAdvertising();

    _connections.clear();
    _subscribedCentrals.clear();
    _pendingPayloads.clear();
    _notifyQueue.dispose();

    await _stateSubscription?.cancel();
    await _connectionStateChangedSubscription?.cancel();
    await _writeRequestedSubscription?.cancel();
    await _notifyStateChangedSubscription?.cancel();
    await _eventController.close();
  }

  void _onConnectionStateChanged(CentralConnectionStateChangedEvent event) {
    final central = event.central;
    final centralId = central.uuid.toString();
    final state = event.state;

    _log('Central connection state changed: $centralId -> $state');

    if (state == ConnectionState.connected) {
      // Track this central if new
      if (!_connections.containsKey(centralId)) {
        _connections[centralId] = central;
        _log('Central connected: $centralId');
        _eventController.add(ConnectionEstablished(id: DeviceId(centralId)));
      }
    } else if (state == ConnectionState.disconnected) {
      // Clean up disconnected central
      final hadConnection = _connections.remove(centralId) != null;
      _subscribedCentrals.remove(centralId);
      _pendingPayloads.remove(centralId);
      _notifyQueue.clear(centralId);

      if (hadConnection) {
        _log('Central disconnected: $centralId');
        _eventController.add(DeviceDisconnected(id: DeviceId(centralId)));
      }
    }
  }

  void _onWriteRequested(GATTCharacteristicWriteRequestedEvent event) {
    final central = event.central;
    final centralId = central.uuid.toString();
    final value = event.request.value;

    // Respond to the write request
    unawaited(_peripheralManager.respondWriteRequest(event.request));

    // Track this central if new (fallback for platforms that don't emit
    // connectionStateChanged before write requests)
    if (!_connections.containsKey(centralId)) {
      _connections[centralId] = central;
      _log('Central connected (via write): $centralId');
      _eventController.add(ConnectionEstablished(id: DeviceId(centralId)));
    }

    if (value.isEmpty) return;

    _log('Received ${value.length} bytes from $centralId');
    _eventController.add(BytesReceived(id: DeviceId(centralId), bytes: value));
  }

  void _onNotifyStateChanged(GATTCharacteristicNotifyStateChangedEvent event) {
    final central = event.central;
    final centralId = central.uuid.toString();
    final subscribed = event.state;

    _log('Central $centralId notify state: $subscribed');

    // Track this central if new (fallback for platforms that don't emit
    // connectionStateChanged before subscription changes)
    if (!_connections.containsKey(centralId)) {
      _connections[centralId] = central;
      _log('Central connected (via subscription): $centralId');
      _eventController.add(ConnectionEstablished(id: DeviceId(centralId)));
    }

    if (subscribed) {
      _subscribedCentrals.add(centralId);

      // Flush pending payloads
      final pending = _pendingPayloads.remove(centralId);
      if (pending != null && pending.isNotEmpty) {
        _log('Flushing ${pending.length} pending payloads to $centralId');
        for (final bytes in pending) {
          unawaited(send(DeviceId(centralId), bytes));
        }
      }
    } else {
      _subscribedCentrals.remove(centralId);
    }
  }
}
