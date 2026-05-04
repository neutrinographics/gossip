import 'dart:async';

import 'package:gossip/gossip.dart';
import 'package:meta/meta.dart';

import '../application/observability/bluey_metrics.dart';
import '../application/services/connection_service.dart';
import '../domain/aggregates/connection_registry.dart';
import '../domain/errors/connection_error.dart';
import '../domain/events/connection_event.dart';
import '../domain/interfaces/bluey_port.dart';
import '../domain/value_objects/service_uuid.dart';
import '../infrastructure/adapters/bluey_port_impl.dart';
import '../infrastructure/ports/bluey_message_port.dart';

/// Sealed event hierarchy emitted by [BlueyTransport.peerEvents].
sealed class PeerEvent {
  const PeerEvent();
}

final class PeerConnected extends PeerEvent {
  final NodeId nodeId;
  final String? displayName;
  const PeerConnected(this.nodeId, {this.displayName});
}

final class PeerDisconnected extends PeerEvent {
  final NodeId nodeId;
  const PeerDisconnected(this.nodeId);
}

/// Public facade for the bluey BLE transport. Mirrors the shape of
/// `NearbyTransport` from `gossip_nearby`.
class BlueyTransport {
  BlueyTransport._({
    required this.localNodeId,
    required ServiceUuid serviceUuid,
    required String displayName,
    required BlueyPort port,
    required ConnectionService service,
    required BlueyMessagePort messagePort,
    LogCallback? onLog,
  })  : _serviceUuid = serviceUuid,
        _displayName = displayName,
        _port = port,
        _service = service,
        _messagePort = messagePort,
        // ignore: unused_field
        _onLog = onLog {
    _eventSub = service.events.listen(_onEvent);
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  /// Creates a transport using the real bluey adapter. Validates the
  /// resolved NodeId is a well-formed UUID before any BLE activity.
  static Future<BlueyTransport> create({
    required LocalNodeRepository localNodeRepository,
    required ServiceUuid serviceUuid,
    required String displayName,
    int? maxConnections,
    int? targetConnections,
    LogCallback? onLog,
  }) async {
    final nodeId = await localNodeRepository.resolveNodeId();
    if (!_uuidPattern.hasMatch(nodeId.value.toLowerCase())) {
      throw ArgumentError.value(
        nodeId.value,
        'localNodeId',
        'gossip_bluey requires NodeId to be a well-formed UUID',
      );
    }
    final port = BlueyPortImpl(localNodeId: nodeId);
    final registry = ConnectionRegistry();
    final metrics = BlueyMetrics();
    final service = ConnectionService(
      localNodeId: nodeId,
      port: port,
      registry: registry,
      metrics: metrics,
      serviceUuid: serviceUuid,
      maxConnections: maxConnections,
      targetConnections: targetConnections,
      onLog: onLog,
    );
    return BlueyTransport._(
      localNodeId: nodeId,
      serviceUuid: serviceUuid,
      displayName: displayName,
      port: port,
      service: service,
      messagePort: BlueyMessagePort(service),
      onLog: onLog,
    );
  }

  /// Test-only constructor that wires a `BlueyPort` directly.
  factory BlueyTransport.testing({
    required NodeId localNodeId,
    required ServiceUuid serviceUuid,
    required String displayName,
    required BlueyPort port,
    int? maxConnections,
    int? targetConnections,
    LogCallback? onLog,
  }) {
    final registry = ConnectionRegistry();
    final metrics = BlueyMetrics();
    final service = ConnectionService(
      localNodeId: localNodeId,
      port: port,
      registry: registry,
      metrics: metrics,
      serviceUuid: serviceUuid,
      maxConnections: maxConnections,
      targetConnections: targetConnections,
      onLog: onLog,
    );
    final mp = BlueyMessagePort(service);
    return BlueyTransport._(
      localNodeId: localNodeId,
      serviceUuid: serviceUuid,
      displayName: displayName,
      port: port,
      service: service,
      messagePort: mp,
      onLog: onLog,
    );
  }

  final NodeId localNodeId;
  final ServiceUuid _serviceUuid;
  final String _displayName;
  final BlueyPort _port;
  final ConnectionService _service;
  final BlueyMessagePort _messagePort;
  // ignore: unused_field
  final LogCallback? _onLog;

  late final StreamSubscription<ConnectionEvent> _eventSub;
  final StreamController<PeerEvent> _peers =
      StreamController<PeerEvent>.broadcast();

  bool _isAdvertising = false;
  bool _isDiscovering = false;

  bool get isAdvertising => _isAdvertising;
  bool get isDiscovering => _isDiscovering;
  MessagePort get messagePort => _messagePort;
  Stream<PeerEvent> get peerEvents => _peers.stream;
  Stream<ConnectionError> get errors => _service.errors;
  Set<NodeId> get connectedPeers =>
      _service.registry.connections.map((h) => h.nodeId).toSet();
  int get connectedPeerCount => _service.registry.connectionCount;
  BlueyMetrics get metrics => _service.metrics;

  /// Test-only access to the underlying ConnectionService for triggering
  /// discovery rounds synchronously in integration tests.
  @visibleForTesting
  ConnectionService get serviceForTest => _service;

  Future<void> startAdvertising() async {
    if (_isAdvertising) return;
    await _port.startAdvertising(
      serviceUuid: _serviceUuid,
      displayName: _displayName,
      localNodeId: localNodeId,
    );
    _isAdvertising = true;
  }

  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;
    await _port.stopAdvertising();
    _isAdvertising = false;
  }

  Future<void> startDiscovery({bool Function(NodeId)? filter}) async {
    await _service.startDiscovery(filter: filter);
    _isDiscovering = true;
  }

  Future<void> stopDiscovery() async {
    await _service.stopDiscovery();
    _isDiscovering = false;
  }

  Future<void> disconnectAll() => _service.disconnectAll();

  Future<void> dispose() async {
    await _eventSub.cancel();
    await _peers.close();
    await _service.dispose();
    await _port.dispose();
  }

  void _onEvent(ConnectionEvent event) {
    switch (event) {
      case PeerOpened(:final nodeId, :final displayName):
        _peers.add(PeerConnected(nodeId, displayName: displayName));
      case PeerClosed(:final nodeId):
        _peers.add(PeerDisconnected(nodeId));
    }
  }
}
