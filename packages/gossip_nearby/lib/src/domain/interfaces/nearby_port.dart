import 'dart:typed_data';

import '../value_objects/endpoint_id.dart';
import '../value_objects/service_id.dart';

/// Port abstraction for Nearby Connections operations.
///
/// The domain defines this interface to specify what it needs from
/// a Nearby Connections implementation. The infrastructure layer
/// provides a concrete adapter implementing this interface.
abstract class NearbyPort {
  /// Starts advertising this device with the given service ID and display name.
  Future<void> startAdvertising(ServiceId serviceId, String displayName);

  /// Stops advertising.
  Future<void> stopAdvertising();

  /// Starts discovering nearby devices with the given service ID.
  Future<void> startDiscovery(ServiceId serviceId);

  /// Stops discovery.
  Future<void> stopDiscovery();

  /// Requests a connection to the given endpoint.
  Future<void> requestConnection(EndpointId endpointId);

  /// Disconnects from the given endpoint.
  Future<void> disconnect(EndpointId endpointId);

  /// Sends a payload to the given endpoint.
  Future<void> sendPayload(EndpointId endpointId, Uint8List bytes);

  /// Stream of events from the Nearby Connections layer.
  Stream<NearbyEvent> get events;
}

/// Events emitted by the Nearby Connections layer.
sealed class NearbyEvent {
  const NearbyEvent();
}

/// An endpoint was discovered during discovery.
class EndpointDiscovered extends NearbyEvent {
  final EndpointId id;
  final String displayName;

  const EndpointDiscovered({required this.id, required this.displayName});

  @override
  String toString() => 'EndpointDiscovered(id: $id, displayName: $displayName)';
}

/// A connection was established to an endpoint.
class ConnectionEstablished extends NearbyEvent {
  final EndpointId id;

  const ConnectionEstablished({required this.id});

  @override
  String toString() => 'ConnectionEstablished(id: $id)';
}

/// A payload was received from an endpoint.
class PayloadReceived extends NearbyEvent {
  final EndpointId id;
  final Uint8List bytes;

  const PayloadReceived({required this.id, required this.bytes});

  @override
  String toString() => 'PayloadReceived(id: $id, bytes: ${bytes.length} bytes)';
}

/// An endpoint is no longer visible during discovery.
class EndpointLost extends NearbyEvent {
  final EndpointId id;

  const EndpointLost({required this.id});

  @override
  String toString() => 'EndpointLost(id: $id)';
}

/// A connection attempt to an endpoint failed at the platform level.
class ConnectionFailed extends NearbyEvent {
  final EndpointId id;
  final String? reason;

  const ConnectionFailed({required this.id, this.reason});

  @override
  String toString() => 'ConnectionFailed(id: $id, reason: $reason)';
}

/// An endpoint disconnected.
class Disconnected extends NearbyEvent {
  final EndpointId id;

  const Disconnected({required this.id});

  @override
  String toString() => 'Disconnected(id: $id)';
}
