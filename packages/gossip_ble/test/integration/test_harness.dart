import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_ble/gossip_ble.dart';

import 'fake_ble_port.dart';

/// Test harness for BLE integration tests.
///
/// Provides a DSL for creating test devices and managing their lifecycle.
/// Uses [InMemoryTimePort] for deterministic, fast tests without real delays.
///
/// ```dart
/// final harness = BleTestHarness();
/// addTearDown(harness.dispose);
///
/// final alice = harness.createDevice('alice');
/// final bob = harness.createDevice('bob');
///
/// await alice.connectTo(bob);
/// await alice.sendTo(bob, [1, 2, 3]);
/// bob.expectReceivedFrom(alice, bytes: [1, 2, 3]);
/// ```
class BleTestHarness {
  final List<TestDevice> _devices = [];
  final ServiceId _serviceId;

  /// The shared time port for all devices in this harness.
  ///
  /// Use [advance] to move time forward and trigger timeouts/delays.
  final InMemoryTimePort timePort;

  // --- Time Constants ---

  /// The default handshake timeout duration (30 seconds).
  static const handshakeTimeout = Duration(seconds: 30);

  BleTestHarness({ServiceId? serviceId, InMemoryTimePort? timePort})
    : _serviceId = serviceId ?? const ServiceId('com.test.ble'),
      timePort = timePort ?? InMemoryTimePort();

  /// Creates a new test device with the given name.
  ///
  /// The optional [messageDelay] simulates network latency. When non-zero,
  /// messages won't be delivered until [advance] is called with sufficient
  /// duration.
  TestDevice createDevice(
    String name, {
    Duration messageDelay = Duration.zero,
  }) {
    return _createDeviceInternal(name, messageDelay: messageDelay);
  }

  /// Creates multiple test devices with the given names.
  ///
  /// ```dart
  /// final [alice, bob, charlie] = harness.createDevices(['alice', 'bob', 'charlie']);
  /// ```
  List<TestDevice> createDevices(
    List<String> names, {
    Duration messageDelay = Duration.zero,
  }) {
    return names
        .map((name) => createDevice(name, messageDelay: messageDelay))
        .toList();
  }

  TestDevice _createDeviceInternal(
    String name, {
    Duration messageDelay = Duration.zero,
  }) {
    final port = FakeBlePort(
      localDeviceId: DeviceId('device-$name'),
      timePort: timePort,
      messageDelay: messageDelay,
    );
    final transport = BleTransport.withPort(
      localNodeId: NodeId(
        'node-$name-${DateTime.now().microsecondsSinceEpoch}',
      ),
      serviceId: _serviceId,
      displayName: 'Device $name',
      blePort: port,
      timePort: timePort,
    );
    final device = TestDevice._(
      name: name,
      port: port,
      transport: transport,
      harness: this,
    );
    _devices.add(device);
    return device;
  }

  /// Disposes all created devices.
  Future<void> dispose() async {
    for (final device in _devices) {
      await device.dispose();
    }
    _devices.clear();
  }

  /// Advances simulated time by the given duration.
  ///
  /// This triggers:
  /// - Scheduled one-shot timers (handshake timeouts)
  /// - Pending delays (message delivery with latency)
  /// - Periodic callbacks
  ///
  /// For most tests, use the default duration which is sufficient for
  /// handshakes to complete without simulated delays.
  Future<void> advance([
    Duration duration = const Duration(milliseconds: 10),
  ]) async {
    await timePort.advance(duration);
  }

  /// Advances time to exactly the handshake timeout (30 seconds).
  ///
  /// Use this when testing timeout behavior.
  Future<void> advanceToHandshakeTimeout() async {
    await advance(handshakeTimeout);
  }

  /// Advances time to just before the handshake timeout (30s - 1ms).
  ///
  /// Use this to verify timeouts don't fire prematurely.
  Future<void> advanceJustBeforeTimeout() async {
    await advance(handshakeTimeout - const Duration(milliseconds: 1));
  }

  /// Advances time well past the handshake timeout (60 seconds).
  ///
  /// Use this to ensure timeouts have definitely fired.
  Future<void> advancePastTimeout() async {
    await advance(const Duration(seconds: 60));
  }

  /// Alias for [advance] - settles any pending async operations.
  @Deprecated('Use advance() instead for clarity')
  Future<void> settle([Duration? duration]) async {
    await advance(duration ?? const Duration(milliseconds: 10));
  }

  // --- Batch Assertions ---

  /// Asserts that all devices in the list are connected to the target.
  ///
  /// ```dart
  /// harness.expectAllConnectedTo([bob, charlie, diana], alice);
  /// ```
  void expectAllConnectedTo(List<TestDevice> devices, TestDevice target) {
    for (final device in devices) {
      device.expectConnectedTo(target);
    }
  }

  /// Asserts that all devices in the list have no errors.
  void expectNoErrorsOnAll(List<TestDevice> devices) {
    for (final device in devices) {
      device.expectNoErrors();
    }
  }

  /// Clears events on all devices in the harness.
  void clearAllEvents() {
    for (final device in _devices) {
      device.clearEvents();
    }
  }
}

/// A test device wrapping FakeBlePort and BleTransport.
///
/// Provides a high-level API for common test operations and assertions.
class TestDevice {
  final String name;
  final FakeBlePort port;
  final BleTransport transport;
  final BleTestHarness _harness;

  final List<PeerEvent> peerEvents = [];
  final List<ConnectionError> errors = [];
  final List<IncomingMessage> receivedMessages = [];

  late final StreamSubscription<PeerEvent> _peerEventSub;
  late final StreamSubscription<ConnectionError> _errorSub;
  late final StreamSubscription<IncomingMessage> _incomingSub;

  bool _disposed = false;
  int _silentPeerCounter = 0;

  TestDevice._({
    required this.name,
    required this.port,
    required this.transport,
    required BleTestHarness harness,
  }) : _harness = harness {
    _peerEventSub = transport.peerEvents.listen(peerEvents.add);
    _errorSub = transport.errors.listen(errors.add);
    _incomingSub = transport.messagePort.incoming.listen(receivedMessages.add);
  }

  // --- Identifiers ---

  /// The device's NodeId.
  NodeId get nodeId => transport.localNodeId;

  /// The device's DeviceId.
  DeviceId get deviceId => port.localDeviceId;

  // --- State Accessors ---

  /// Number of connected peers.
  int get connectedPeerCount => transport.connectedPeerCount;

  /// Connected peer NodeIds.
  Set<NodeId> get connectedPeers => transport.connectedPeers;

  /// Metrics for this device.
  BleMetrics get metrics => transport.metrics;

  /// Whether this device is advertising.
  bool get isAdvertising => transport.isAdvertising;

  /// Whether this device is discovering.
  bool get isDiscovering => transport.isDiscovering;

  // --- Connection Operations ---

  /// Establishes a bidirectional connection with another device.
  ///
  /// Advances time to allow the handshake to complete.
  Future<void> connectTo(TestDevice other) async {
    FakeBlePort.connect(port, other.port);
    await _harness.advance();
  }

  /// Establishes bidirectional connections with multiple devices.
  ///
  /// ```dart
  /// await alice.connectToAll([bob, charlie, diana]);
  /// ```
  Future<void> connectToAll(List<TestDevice> others) async {
    for (final other in others) {
      await connectTo(other);
    }
  }

  /// Disconnects from another device.
  Future<void> disconnectFrom(TestDevice other) async {
    await port.disconnect(other.deviceId);
    await _harness.advance();
  }

  /// Disconnects from multiple devices.
  Future<void> disconnectFromAll(List<TestDevice> others) async {
    for (final other in others) {
      await disconnectFrom(other);
    }
  }

  /// Simulates an incoming connection from an unknown device (one-way).
  ///
  /// Note: Sends to this device will fail. Use [simulateSilentConnection]
  /// for timeout testing where sends should succeed.
  void simulateIncomingConnection(DeviceId deviceId) {
    port.simulateIncomingConnection(deviceId);
  }

  /// Simulates a connection to a "silent" peer that accepts messages but
  /// never responds.
  ///
  /// This is useful for testing handshake timeout scenarios where:
  /// - The connection is established
  /// - Our handshake message is sent successfully
  /// - The peer never sends their handshake response
  void simulateSilentConnection(DeviceId deviceId) {
    port.simulateSilentConnection(deviceId);
  }

  /// Creates and connects to a silent peer, returning its DeviceId.
  ///
  /// This is a convenience method that combines DeviceId creation with
  /// [simulateSilentConnection]. Useful for timeout tests.
  ///
  /// ```dart
  /// final silentPeer = alice.connectToSilentPeer();
  /// await harness.advanceToHandshakeTimeout();
  /// alice.expectError<HandshakeTimeoutError>(deviceId: silentPeer);
  /// ```
  DeviceId connectToSilentPeer([String prefix = 'silent']) {
    final deviceId = DeviceId('$prefix-${_silentPeerCounter++}');
    simulateSilentConnection(deviceId);
    return deviceId;
  }

  /// Creates multiple silent peer connections, returning their DeviceIds.
  List<DeviceId> connectToSilentPeers(int count, [String prefix = 'silent']) {
    return List.generate(count, (_) => connectToSilentPeer(prefix));
  }

  /// Simulates receiving raw bytes from a device.
  ///
  /// Useful for testing malformed data handling.
  void simulateBytesReceived(DeviceId deviceId, Uint8List bytes) {
    port.simulateBytesReceived(deviceId, bytes);
  }

  /// Simulates a device disconnecting (one-way).
  void simulateDisconnection(DeviceId deviceId) {
    port.simulateDisconnection(deviceId);
  }

  // --- Messaging Operations ---

  /// Sends a message to another device.
  ///
  /// Advances time to allow message delivery.
  Future<void> sendTo(TestDevice other, List<int> bytes) async {
    await transport.messagePort.send(other.nodeId, Uint8List.fromList(bytes));
    await _harness.advance();
  }

  /// Sends raw bytes to a NodeId (may not exist).
  Future<void> sendToNodeId(NodeId nodeId, List<int> bytes) async {
    await transport.messagePort.send(nodeId, Uint8List.fromList(bytes));
    await _harness.advance();
  }

  // --- Advertising/Discovery ---

  /// Starts advertising.
  Future<void> startAdvertising() async {
    await transport.startAdvertising();
  }

  /// Stops advertising.
  Future<void> stopAdvertising() async {
    await transport.stopAdvertising();
  }

  /// Starts discovery.
  Future<void> startDiscovery() async {
    await transport.startDiscovery();
  }

  /// Stops discovery.
  Future<void> stopDiscovery() async {
    await transport.stopDiscovery();
  }

  // --- Failure Injection ---

  /// Makes all send operations fail.
  void failAllSends() {
    port.failSends = true;
  }

  /// Makes send operations succeed again.
  void succeedAllSends() {
    port.failSends = false;
  }

  /// Makes sends to a specific device fail.
  void failSendsTo(TestDevice other) {
    port.failSendsToDevices.add(other.deviceId);
  }

  /// Makes sends to a specific DeviceId fail.
  void failSendsToDevice(DeviceId deviceId) {
    port.failSendsToDevices.add(deviceId);
  }

  /// Makes sends to a specific device succeed again.
  void succeedSendsTo(TestDevice other) {
    port.failSendsToDevices.remove(other.deviceId);
  }

  // --- Assertions ---

  /// Asserts that this device is connected to another.
  void expectConnectedTo(TestDevice other) {
    expect(
      connectedPeers,
      contains(other.nodeId),
      reason: '$name should be connected to ${other.name}',
    );
  }

  /// Asserts that this device is not connected to another.
  void expectNotConnectedTo(TestDevice other) {
    expect(
      connectedPeers,
      isNot(contains(other.nodeId)),
      reason: '$name should not be connected to ${other.name}',
    );
  }

  /// Asserts the number of connected peers.
  void expectPeerCount(int count) {
    expect(
      connectedPeerCount,
      count,
      reason: '$name should have $count connected peers',
    );
  }

  /// Asserts that a PeerConnected event was received for another device.
  void expectPeerConnectedEvent(TestDevice other) {
    final connected = peerEvents.whereType<PeerConnected>().toList();
    expect(
      connected.map((e) => e.nodeId),
      contains(other.nodeId),
      reason: '$name should have received PeerConnected for ${other.name}',
    );
  }

  /// Asserts that a PeerDisconnected event was received for another device.
  void expectPeerDisconnectedEvent(TestDevice other) {
    final disconnected = peerEvents.whereType<PeerDisconnected>().toList();
    expect(
      disconnected.map((e) => e.nodeId),
      contains(other.nodeId),
      reason: '$name should have received PeerDisconnected for ${other.name}',
    );
  }

  /// Asserts that an error of type T was recorded.
  ///
  /// Optionally validates the error's deviceId and message content.
  /// Returns the first matching error for further assertions if needed.
  ///
  /// ```dart
  /// alice.expectError<HandshakeTimeoutError>();
  /// alice.expectError<HandshakeTimeoutError>(deviceId: silentPeer);
  /// alice.expectError<SendFailedError>(messageContains: 'failed');
  /// ```
  T expectError<T extends ConnectionError>({
    DeviceId? deviceId,
    String? messageContains,
    String? reason,
  }) {
    var matches = errors.whereType<T>();

    if (deviceId != null) {
      matches = matches.where((e) {
        if (e is HandshakeTimeoutError) return e.deviceId == deviceId;
        if (e is HandshakeInvalidError) return e.deviceId == deviceId;
        return true;
      });
    }

    if (messageContains != null) {
      matches = matches.where((e) => e.message.contains(messageContains));
    }

    expect(
      matches,
      isNotEmpty,
      reason: reason ?? '$name should have received ${T.toString()} error',
    );

    return matches.first;
  }

  /// Asserts that no errors of type T were recorded.
  void expectNoError<T extends ConnectionError>() {
    expect(
      errors.whereType<T>(),
      isEmpty,
      reason: '$name should not have received ${T.toString()} error',
    );
  }

  /// Asserts that no errors were recorded at all.
  void expectNoErrors() {
    expect(errors, isEmpty, reason: '$name should not have any errors');
  }

  /// Gets the count of errors of type T.
  int errorCount<T extends ConnectionError>() {
    return errors.whereType<T>().length;
  }

  /// Asserts the exact count of errors of type T.
  void expectErrorCount<T extends ConnectionError>(int count) {
    expect(
      errorCount<T>(),
      count,
      reason: '$name should have exactly $count ${T.toString()} errors',
    );
  }

  /// Asserts that a message was received from another device.
  void expectReceivedFrom(TestDevice other, {List<int>? bytes}) {
    final fromOther = receivedMessages.where((m) => m.sender == other.nodeId);
    expect(
      fromOther,
      isNotEmpty,
      reason: '$name should have received a message from ${other.name}',
    );
    if (bytes != null) {
      expect(
        fromOther.any((m) => _bytesEqual(m.bytes, Uint8List.fromList(bytes))),
        isTrue,
        reason: '$name should have received specific bytes from ${other.name}',
      );
    }
  }

  /// Asserts that a specific message was received from another device.
  ///
  /// Alias for [expectReceivedFrom] with named parameters for clarity.
  void expectReceivedMessage({
    required TestDevice from,
    required List<int> bytes,
  }) {
    expectReceivedFrom(from, bytes: bytes);
  }

  /// Asserts that no messages were received from another device.
  void expectNoMessagesFrom(TestDevice other) {
    final fromOther = receivedMessages.where((m) => m.sender == other.nodeId);
    expect(
      fromOther,
      isEmpty,
      reason: '$name should not have received messages from ${other.name}',
    );
  }

  /// Asserts the total number of received messages.
  void expectReceivedCount(int count) {
    expect(
      receivedMessages.length,
      count,
      reason: '$name should have received $count messages',
    );
  }

  /// Gets the count of received messages from a specific device.
  int receivedCountFrom(TestDevice other) {
    return receivedMessages.where((m) => m.sender == other.nodeId).length;
  }

  /// Asserts metrics values.
  void expectMetrics({
    int? totalConnectionsEstablished,
    int? totalHandshakesCompleted,
    int? totalHandshakesFailed,
    int? connectedPeerCount,
    int? pendingHandshakeCount,
  }) {
    if (totalConnectionsEstablished != null) {
      expect(
        metrics.totalConnectionsEstablished,
        totalConnectionsEstablished,
        reason: '$name totalConnectionsEstablished',
      );
    }
    if (totalHandshakesCompleted != null) {
      expect(
        metrics.totalHandshakesCompleted,
        totalHandshakesCompleted,
        reason: '$name totalHandshakesCompleted',
      );
    }
    if (totalHandshakesFailed != null) {
      expect(
        metrics.totalHandshakesFailed,
        totalHandshakesFailed,
        reason: '$name totalHandshakesFailed',
      );
    }
    if (connectedPeerCount != null) {
      expect(
        metrics.connectedPeerCount,
        connectedPeerCount,
        reason: '$name connectedPeerCount (metrics)',
      );
    }
    if (pendingHandshakeCount != null) {
      expect(
        metrics.pendingHandshakeCount,
        pendingHandshakeCount,
        reason: '$name pendingHandshakeCount',
      );
    }
  }

  // --- Event Clearing ---

  /// Clears all collected events and errors.
  void clearEvents() {
    peerEvents.clear();
    errors.clear();
    receivedMessages.clear();
  }

  /// Clears only peer events.
  void clearPeerEvents() {
    peerEvents.clear();
  }

  /// Clears only errors.
  void clearErrors() {
    errors.clear();
  }

  /// Clears only received messages.
  void clearReceivedMessages() {
    receivedMessages.clear();
  }

  // --- Lifecycle ---

  /// Disposes this device's resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _peerEventSub.cancel();
    await _errorSub.cancel();
    await _incomingSub.cancel();
    await transport.dispose();
  }

  @override
  String toString() => 'TestDevice($name)';

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// --- Test Data Helpers ---

/// Common invalid byte sequences for testing malformed data handling.
class MalformedData {
  MalformedData._();

  /// Empty bytes.
  static Uint8List get empty => Uint8List(0);

  /// Single byte that's not a valid message type.
  static Uint8List get unknownMessageType => Uint8List.fromList([0x03]);

  /// Invalid handshake: correct type byte but no payload.
  static Uint8List get handshakeNoPayload => Uint8List.fromList([0x01]);

  /// Invalid handshake: type byte + length but no actual data.
  static Uint8List get handshakeTruncated =>
      Uint8List.fromList([0x01, 0x00, 0x00, 0x00, 0x05]);

  /// Invalid handshake: length claims more bytes than present.
  static Uint8List get handshakeLengthOverflow => Uint8List.fromList([
    0x01, // type
    0x00, 0x00, 0x00, 0xFF, // length: 255 bytes claimed
    0x41, 0x42, 0x43, // only 3 bytes present
  ]);

  /// Invalid handshake: contains invalid UTF-8 sequence.
  static Uint8List get handshakeInvalidUtf8 => Uint8List.fromList([
    0x01, // type
    0x00, 0x00, 0x00, 0x04, // length: 4 bytes
    0xFF, 0xFE, 0x00, 0x01, // invalid UTF-8
  ]);

  /// Invalid gossip: correct type but no payload.
  static Uint8List get gossipNoPayload => Uint8List.fromList([0x02]);

  /// Random garbage bytes.
  static Uint8List get randomGarbage =>
      Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE]);

  /// Valid looking handshake with empty NodeId.
  static Uint8List get handshakeEmptyNodeId => Uint8List.fromList([
    0x01, // type
    0x00, 0x00, 0x00, 0x00, // length: 0 bytes
  ]);
}
