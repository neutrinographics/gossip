import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';
import 'package:gossip_ble/gossip_ble.dart';
import 'package:gossip_ble/src/domain/ports/ble_port.dart';

/// A fake BlePort implementation for integration testing.
///
/// This allows simulating realistic BLE scenarios including:
/// - Multiple devices connecting/disconnecting
/// - Message delivery with optional delays (via TimePort)
/// - Connection failures and timeouts
/// - Cross-device communication (two FakeBlePort instances can talk to each other)
class FakeBlePort implements BlePort {
  final _eventController = StreamController<BleEvent>.broadcast();
  final Map<DeviceId, FakeBlePort> _connectedPeers = {};
  final Map<DeviceId, List<Uint8List>> _pendingMessages = {};
  final Set<DeviceId> _silentPeers = {};

  DeviceId? _localDeviceId;
  ServiceId? _advertisingServiceId;
  String? _advertisingDisplayName;
  bool _isAdvertising = false;
  bool _isDiscovering = false;
  bool _isDisposed = false;

  /// The TimePort to use for message delays.
  final TimePort timePort;

  /// Optional delay for simulating network latency.
  final Duration messageDelay;

  /// If true, send() will throw an exception.
  bool failSends = false;

  /// If true, requestConnection() will throw an exception.
  bool failConnections = false;

  /// Custom send failure for specific devices.
  final Set<DeviceId> failSendsToDevices = {};

  FakeBlePort({
    DeviceId? localDeviceId,
    required this.timePort,
    this.messageDelay = Duration.zero,
  }) : _localDeviceId = localDeviceId;

  /// The local device ID for this port.
  DeviceId get localDeviceId {
    _localDeviceId ??= DeviceId('fake-device-${identityHashCode(this)}');
    return _localDeviceId!;
  }

  @override
  Stream<BleEvent> get events => _eventController.stream;

  /// Whether this port is currently advertising.
  bool get isAdvertising => _isAdvertising;

  /// Whether this port is currently discovering.
  bool get isDiscovering => _isDiscovering;

  /// Currently connected peer device IDs.
  Set<DeviceId> get connectedPeerIds => _connectedPeers.keys.toSet();

  @override
  Future<void> startAdvertising(ServiceId serviceId, String displayName) async {
    _checkNotDisposed();
    _advertisingServiceId = serviceId;
    _advertisingDisplayName = displayName;
    _isAdvertising = true;
  }

  @override
  Future<void> stopAdvertising() async {
    _checkNotDisposed();
    _isAdvertising = false;
    _advertisingServiceId = null;
    _advertisingDisplayName = null;
  }

  @override
  Future<void> startDiscovery(ServiceId serviceId) async {
    _checkNotDisposed();
    _isDiscovering = true;
  }

  @override
  Future<void> stopDiscovery() async {
    _checkNotDisposed();
    _isDiscovering = false;
  }

  @override
  Future<void> requestConnection(DeviceId deviceId) async {
    _checkNotDisposed();
    if (failConnections) {
      throw Exception('Connection failed (simulated)');
    }
    // Connection is established via simulateConnection
  }

  @override
  Future<void> disconnect(DeviceId deviceId) async {
    _checkNotDisposed();
    final peer = _connectedPeers.remove(deviceId);
    _pendingMessages.remove(deviceId);

    if (peer != null) {
      // Notify local side
      _eventController.add(DeviceDisconnected(id: deviceId));
      // Notify remote side
      peer._handlePeerDisconnected(localDeviceId);
    }
  }

  @override
  Future<void> send(DeviceId deviceId, Uint8List bytes) async {
    _checkNotDisposed();

    if (failSends || failSendsToDevices.contains(deviceId)) {
      throw Exception('Send failed (simulated)');
    }

    // Silent peers accept messages but never respond (for timeout testing)
    if (_silentPeers.contains(deviceId)) {
      if (messageDelay > Duration.zero) {
        await timePort.delay(messageDelay);
      }
      return; // Message accepted but goes nowhere
    }

    final peer = _connectedPeers[deviceId];
    if (peer == null) {
      throw Exception('Not connected to $deviceId');
    }

    if (messageDelay > Duration.zero) {
      await timePort.delay(messageDelay);
    }

    // Deliver to the peer
    peer._receiveBytes(localDeviceId, bytes);
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    // Disconnect all peers without checking disposed state
    for (final deviceId in _connectedPeers.keys.toList()) {
      final peer = _connectedPeers.remove(deviceId);
      _pendingMessages.remove(deviceId);
      // Notify remote side only (skip local events since we're disposing)
      peer?._handlePeerDisconnected(localDeviceId);
    }

    await _eventController.close();
  }

  // --- Simulation methods ---

  /// Simulates discovering a device.
  void simulateDeviceDiscovered(DeviceId deviceId, String displayName) {
    _checkNotDisposed();
    _eventController.add(
      DeviceDiscovered(id: deviceId, displayName: displayName),
    );
  }

  /// Establishes a bidirectional connection between two FakeBlePort instances.
  ///
  /// This simulates a real BLE connection where both sides see the connection.
  static void connect(FakeBlePort portA, FakeBlePort portB) {
    portA._checkNotDisposed();
    portB._checkNotDisposed();

    // Register each other as connected peers
    portA._connectedPeers[portB.localDeviceId] = portB;
    portB._connectedPeers[portA.localDeviceId] = portA;

    // Emit connection established events on both sides
    portA._eventController.add(ConnectionEstablished(id: portB.localDeviceId));
    portB._eventController.add(ConnectionEstablished(id: portA.localDeviceId));
  }

  /// Simulates an incoming connection from a device (one-way, for simpler tests).
  ///
  /// Note: This only emits the event - sends to this device will fail.
  /// Use [simulateSilentConnection] if you need sends to succeed but the
  /// peer to never respond (for timeout testing).
  void simulateIncomingConnection(DeviceId deviceId) {
    _checkNotDisposed();
    _eventController.add(ConnectionEstablished(id: deviceId));
  }

  /// Simulates a connection to a "silent" peer that accepts messages but
  /// never responds.
  ///
  /// This is useful for testing handshake timeout scenarios where:
  /// - The connection is established
  /// - Our handshake message is sent successfully
  /// - The peer never sends their handshake response
  ///
  /// Use [simulateDisconnection] to disconnect the silent peer.
  void simulateSilentConnection(DeviceId deviceId) {
    _checkNotDisposed();
    _silentPeers.add(deviceId);
    _eventController.add(ConnectionEstablished(id: deviceId));
  }

  /// Simulates receiving bytes from a device (for tests not using two-port setup).
  void simulateBytesReceived(DeviceId deviceId, Uint8List bytes) {
    _checkNotDisposed();
    _eventController.add(BytesReceived(id: deviceId, bytes: bytes));
  }

  /// Simulates a device disconnecting (for tests not using two-port setup).
  void simulateDisconnection(DeviceId deviceId) {
    _checkNotDisposed();
    _connectedPeers.remove(deviceId);
    _pendingMessages.remove(deviceId);
    _silentPeers.remove(deviceId);
    _eventController.add(DeviceDisconnected(id: deviceId));
  }

  // --- Internal methods ---

  void _receiveBytes(DeviceId fromDevice, Uint8List bytes) {
    if (_isDisposed) return;
    _eventController.add(BytesReceived(id: fromDevice, bytes: bytes));
  }

  void _handlePeerDisconnected(DeviceId peerId) {
    if (_isDisposed) return;
    _connectedPeers.remove(peerId);
    _pendingMessages.remove(peerId);
    _eventController.add(DeviceDisconnected(id: peerId));
  }

  void _checkNotDisposed() {
    if (_isDisposed) {
      throw StateError('BlePort has been disposed');
    }
  }
}
