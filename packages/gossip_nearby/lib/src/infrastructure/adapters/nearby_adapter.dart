import 'dart:async' show StreamController, unawaited;
import 'dart:typed_data';

import 'package:nearby_connections/nearby_connections.dart';

import '../../domain/interfaces/nearby_port.dart';
import '../../domain/value_objects/endpoint_id.dart';
import '../../domain/value_objects/service_id.dart';

/// Implements [NearbyPort] using the `nearby_connections` Flutter plugin.
///
/// This adapter translates between the domain's port interface and
/// the platform-specific Nearby Connections API.
class NearbyAdapter implements NearbyPort {
  final Nearby _nearby;
  final _eventController = StreamController<NearbyEvent>.broadcast();

  bool _isAdvertising = false;
  bool _isDiscovering = false;

  NearbyAdapter({Nearby? nearby}) : _nearby = nearby ?? Nearby();

  @override
  Stream<NearbyEvent> get events => _eventController.stream;

  @override
  Future<void> startAdvertising(ServiceId serviceId, String displayName) async {
    if (_isAdvertising) return;

    final started = await _nearby.startAdvertising(
      displayName,
      Strategy.P2P_CLUSTER,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
      serviceId: serviceId.value,
    );

    if (started) {
      _isAdvertising = true;
    }
  }

  @override
  Future<void> stopAdvertising() async {
    if (!_isAdvertising) return;
    await _nearby.stopAdvertising();
    _isAdvertising = false;
  }

  @override
  Future<void> startDiscovery(ServiceId serviceId) async {
    if (_isDiscovering) return;

    final started = await _nearby.startDiscovery(
      '', // userName not needed for discovery
      Strategy.P2P_CLUSTER,
      onEndpointFound: _onEndpointFound,
      onEndpointLost: _onEndpointLost,
      serviceId: serviceId.value,
    );

    if (started) {
      _isDiscovering = true;
    }
  }

  @override
  Future<void> stopDiscovery() async {
    if (!_isDiscovering) return;
    await _nearby.stopDiscovery();
    _isDiscovering = false;
  }

  @override
  Future<void> requestConnection(EndpointId endpointId) async {
    await _nearby.requestConnection(
      '', // userName
      endpointId.value,
      onConnectionInitiated: _onConnectionInitiated,
      onConnectionResult: _onConnectionResult,
      onDisconnected: _onDisconnected,
    );
  }

  @override
  Future<void> disconnect(EndpointId endpointId) async {
    await _nearby.disconnectFromEndpoint(endpointId.value);
  }

  @override
  Future<void> sendPayload(EndpointId endpointId, Uint8List bytes) async {
    await _nearby.sendBytesPayload(endpointId.value, bytes);
  }

  /// Disposes resources.
  Future<void> dispose() async {
    await stopAdvertising();
    await stopDiscovery();
    await _eventController.close();
  }

  // --- Nearby Callbacks ---

  void _onEndpointFound(
    String endpointId,
    String endpointName,
    String serviceId,
  ) {
    _eventController.add(
      EndpointDiscovered(id: EndpointId(endpointId), displayName: endpointName),
    );
  }

  void _onEndpointLost(String? endpointId) {
    // Endpoint lost during discovery - no action needed
  }

  void _onConnectionInitiated(String endpointId, ConnectionInfo info) {
    // Auto-accept all connections
    unawaited(
      _nearby.acceptConnection(
        endpointId,
        onPayLoadRecieved: (endpointId, payload) =>
            _onPayloadReceived(endpointId, payload),
        onPayloadTransferUpdate: (endpointId, update) {},
      ),
    );
  }

  void _onConnectionResult(String endpointId, Status status) {
    if (status == Status.CONNECTED) {
      _eventController.add(ConnectionEstablished(id: EndpointId(endpointId)));
    }
  }

  void _onDisconnected(String endpointId) {
    _eventController.add(Disconnected(id: EndpointId(endpointId)));
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type != PayloadType.BYTES || payload.bytes == null) return;

    _eventController.add(
      PayloadReceived(id: EndpointId(endpointId), bytes: payload.bytes!),
    );
  }
}
