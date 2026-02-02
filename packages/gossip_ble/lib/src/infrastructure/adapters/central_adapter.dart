import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy_platform_interface/bluetooth_low_energy_platform_interface.dart';

import '../../domain/ports/ble_port.dart';
import '../../domain/value_objects/device_id.dart';
import '../util/notification_buffer.dart';
import '../util/write_queue.dart';

/// Callback for logging adapter events.
typedef AdapterLogCallback = void Function(String message);

/// Nordic UART Service UUIDs.
abstract class NusUuids {
  static final service = UUID.fromString(
    '6E400001-B5A3-F393-E0A9-E50E24DCCA9E',
  );
  static final tx = UUID.fromString('6E400002-B5A3-F393-E0A9-E50E24DCCA9E');
  static final rx = UUID.fromString('6E400003-B5A3-F393-E0A9-E50E24DCCA9E');
}

/// Holds connection state for a connected peripheral.
class CentralConnection {
  final Peripheral peripheral;
  final GATTCharacteristic? txCharacteristic;
  final GATTCharacteristic? rxCharacteristic;

  CentralConnection({
    required this.peripheral,
    this.txCharacteristic,
    this.rxCharacteristic,
  });
}

/// Manages the Central role: scanning for and connecting to peripherals.
///
/// ## Connection Setup
///
/// When connecting to a peripheral, there's a brief window where BLE
/// notifications may arrive before the connection is fully registered.
/// This adapter uses a [NotificationBuffer] to capture these early
/// notifications and replay them after setup completes.
///
/// ## Known Limitation: Concurrent Connections
///
/// **WARNING:** If multiple connections are being set up simultaneously,
/// notifications that arrive during setup may be attributed to the wrong
/// device. This is because the BLE platform doesn't provide a way to
/// determine which peripheral a characteristic belongs to during the
/// notification callback before connection setup is complete.
///
/// **Recommendation:** When possible, establish connections sequentially
/// rather than concurrently to avoid potential notification misattribution.
/// This is most relevant during initial discovery when multiple devices
/// may be found at once.
class CentralAdapter {
  final CentralManager _centralManager;
  final WriteQueue _writeQueue;
  final NotificationBuffer _notificationBuffer;
  final AdapterLogCallback? _onLog;

  final _eventController = StreamController<BleEvent>.broadcast();

  // Discovered peripherals (not yet connected)
  final Map<String, Peripheral> _discovered = {};

  // Connected peripherals
  final Map<String, CentralConnection> _connections = {};

  // Subscriptions
  StreamSubscription? _discoveredSubscription;
  StreamSubscription? _connectionStateChangedSubscription;
  StreamSubscription? _characteristicNotifiedSubscription;
  StreamSubscription? _stateSubscription;

  bool _isDiscovering = false;

  CentralAdapter({
    CentralManager? centralManager,
    WriteQueue? writeQueue,
    NotificationBuffer? notificationBuffer,
    AdapterLogCallback? onLog,
  }) : _centralManager = centralManager ?? CentralManager(),
       _writeQueue = writeQueue ?? WriteQueue(),
       _notificationBuffer = notificationBuffer ?? NotificationBuffer(),
       _onLog = onLog {
    _setupSubscriptions();
  }

  Stream<BleEvent> get events => _eventController.stream;

  void _log(String message) {
    _onLog?.call('[Central] $message');
  }

  void _setupSubscriptions() {
    _stateSubscription = _centralManager.stateChanged.listen((event) {
      _log('State changed: ${event.state}');
    });

    _discoveredSubscription = _centralManager.discovered.listen(
      _onPeripheralDiscovered,
    );

    _connectionStateChangedSubscription = _centralManager.connectionStateChanged
        .listen(_onConnectionStateChanged);

    _characteristicNotifiedSubscription = _centralManager.characteristicNotified
        .listen(_onCharacteristicNotified);
  }

  Future<void> startDiscovery() async {
    if (_isDiscovering) return;

    final state = await _centralManager.getState();
    if (state != BluetoothLowEnergyState.on) {
      _log('Bluetooth not on, cannot discover');
      return;
    }

    _discovered.clear();

    _log('Starting discovery...');
    await _centralManager.startDiscovery(serviceUUIDs: [NusUuids.service]);
    _isDiscovering = true;
  }

  Future<void> stopDiscovery() async {
    if (!_isDiscovering) return;

    _log('Stopping discovery...');
    await _centralManager.stopDiscovery();
    _isDiscovering = false;
  }

  Future<void> connect(DeviceId deviceId) async {
    final peripheral = _discovered[deviceId.value];
    if (peripheral == null) {
      _log('Unknown peripheral: ${deviceId.value}');
      return;
    }

    _log('Connecting to ${deviceId.value}...');
    await _centralManager.connect(peripheral);
  }

  Future<void> disconnect(DeviceId deviceId) async {
    final connection = _connections[deviceId.value];
    if (connection == null) return;

    _log('Disconnecting from ${deviceId.value}...');
    await _centralManager.disconnect(connection.peripheral);
    _connections.remove(deviceId.value);
    _writeQueue.clear(deviceId.value);
    _notificationBuffer.clear(deviceId.value);
  }

  Future<void> send(DeviceId deviceId, Uint8List bytes) async {
    final connection = _connections[deviceId.value];
    if (connection?.txCharacteristic == null) {
      _log('No TX characteristic for ${deviceId.value}');
      return;
    }

    await _writeQueue.enqueue(deviceId.value, () async {
      await _centralManager.writeCharacteristic(
        connection!.txCharacteristic!,
        value: bytes,
        type: GATTCharacteristicWriteType.withResponse,
      );
    });
  }

  bool hasConnection(DeviceId deviceId) {
    return _connections.containsKey(deviceId.value);
  }

  Future<void> dispose() async {
    await stopDiscovery();

    for (final connection in _connections.values) {
      try {
        await _centralManager.disconnect(connection.peripheral);
      } catch (_) {}
    }

    _connections.clear();
    _discovered.clear();
    _writeQueue.dispose();
    _notificationBuffer.dispose();

    await _stateSubscription?.cancel();
    await _discoveredSubscription?.cancel();
    await _connectionStateChangedSubscription?.cancel();
    await _characteristicNotifiedSubscription?.cancel();
    await _eventController.close();
  }

  void _onPeripheralDiscovered(DiscoveredEvent event) {
    final peripheral = event.peripheral;
    final peripheralId = peripheral.uuid.toString();

    if (_discovered.containsKey(peripheralId)) return;

    _discovered[peripheralId] = peripheral;

    final displayName =
        event.advertisement.name ?? peripheralId.substring(0, 8);

    _log('Discovered: $peripheralId ($displayName)');

    _eventController.add(
      DeviceDiscovered(id: DeviceId(peripheralId), displayName: displayName),
    );
  }

  void _onConnectionStateChanged(PeripheralConnectionStateChangedEvent event) {
    final peripheral = event.peripheral;
    final peripheralId = peripheral.uuid.toString();
    final state = event.state;

    _log('Connection state changed: $peripheralId -> $state');

    if (state == ConnectionState.connected) {
      _notificationBuffer.markSetupInProgress(peripheralId);
      unawaited(_setupConnection(peripheral));
    } else if (state == ConnectionState.disconnected) {
      final hadConnection = _connections.remove(peripheralId) != null;
      _writeQueue.clear(peripheralId);
      _notificationBuffer.clear(peripheralId);

      if (hadConnection) {
        _eventController.add(DeviceDisconnected(id: DeviceId(peripheralId)));
      }
    }
  }

  Future<void> _setupConnection(Peripheral peripheral) async {
    final peripheralId = peripheral.uuid.toString();

    try {
      // Request larger MTU
      try {
        final mtu = await _centralManager.requestMTU(peripheral, mtu: 512);
        _log('MTU for $peripheralId: $mtu');
      } catch (e) {
        _log('MTU request failed (continuing): $e');
      }

      // Discover services
      final services = await _centralManager.discoverServices(peripheral);

      GATTService? nusService;
      for (final service in services) {
        if (service.uuid == NusUuids.service) {
          nusService = service;
          break;
        }
      }

      if (nusService == null) {
        _log('NUS service not found on $peripheralId');
        await _centralManager.disconnect(peripheral);
        return;
      }

      // Discover characteristics
      final characteristics = await _centralManager.discoverCharacteristics(
        nusService,
      );

      GATTCharacteristic? txChar;
      GATTCharacteristic? rxChar;
      for (final char in characteristics) {
        if (char.uuid == NusUuids.tx) {
          txChar = char;
        } else if (char.uuid == NusUuids.rx) {
          rxChar = char;
        }
      }

      if (txChar == null || rxChar == null) {
        _log('TX/RX characteristics not found on $peripheralId');
        await _centralManager.disconnect(peripheral);
        return;
      }

      // Subscribe to notifications
      await _centralManager.setCharacteristicNotifyState(rxChar, state: true);

      // Store connection
      _connections[peripheralId] = CentralConnection(
        peripheral: peripheral,
        txCharacteristic: txChar,
        rxCharacteristic: rxChar,
      );

      _notificationBuffer.markSetupComplete(peripheralId);

      _log(
        'Connection setup complete: $peripheralId, '
        'rxChar hashCode=${rxChar.hashCode}',
      );
      _eventController.add(ConnectionEstablished(id: DeviceId(peripheralId)));

      // Replay buffered notifications
      final buffered = _notificationBuffer.flushBuffer(peripheralId);
      if (buffered.isNotEmpty) {
        _log('Replaying ${buffered.length} buffered notifications');
        for (final bytes in buffered) {
          _eventController.add(
            BytesReceived(id: DeviceId(peripheralId), bytes: bytes),
          );
        }
      }
    } catch (e) {
      _log('Connection setup failed for $peripheralId: $e');
      _notificationBuffer.clear(peripheralId);
      try {
        await _centralManager.disconnect(peripheral);
      } catch (_) {}
    }
  }

  void _onCharacteristicNotified(GATTCharacteristicNotifiedEvent event) {
    final value = event.value;
    if (value.isEmpty) return;

    _log(
      'Notification received: ${value.length} bytes, '
      'char uuid=${event.characteristic.uuid}, '
      'char hashCode=${event.characteristic.hashCode}, '
      'connections=${_connections.length}',
    );

    // Find which peripheral this characteristic belongs to
    String? peripheralId;
    for (final entry in _connections.entries) {
      final storedChar = entry.value.rxCharacteristic;
      final eventChar = event.characteristic;
      final matches = storedChar == eventChar;
      _log(
        'Comparing with ${entry.key}: '
        'stored hashCode=${storedChar?.hashCode}, '
        'event hashCode=${eventChar.hashCode}, '
        'matches=$matches',
      );
      if (matches) {
        peripheralId = entry.key;
        break;
      }
    }

    if (peripheralId == null) {
      // Connection not registered yet - try to buffer
      // We don't know the peripheralId from the characteristic alone,
      // so we check if any setup is in progress
      for (final id in _notificationBuffer.setupInProgressIds) {
        if (_notificationBuffer.bufferIfNeeded(id, value)) {
          _log('Buffered ${value.length} bytes during setup');
          return;
        }
      }
      _log(
        'Notification from unknown characteristic (${value.length} bytes). '
        'Active connections: ${_connections.keys.toList()}',
      );
      return;
    }

    _log('Received ${value.length} bytes from $peripheralId');
    _eventController.add(
      BytesReceived(id: DeviceId(peripheralId), bytes: value),
    );
  }
}
