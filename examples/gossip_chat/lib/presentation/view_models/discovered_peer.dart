import 'package:flutter/foundation.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

/// Status of a row on the peers list. Subsumes the older three-value
/// connection status (connected/suspected/unreachable) by adding the
/// never-connected, in-flight, and post-failure states the new UI exposes.
enum DiscoveredPeerStatus {
  /// Scanner has seen this address; no connection has been attempted yet.
  discovered,

  /// `connectTo` is in flight.
  connecting,

  /// Connected (in the connection registry); SWIM says reachable.
  connected,

  /// Connected; SWIM probes are failing intermittently.
  suspected,

  /// Connected; SWIM probes are sustained-failing.
  unreachable,

  /// Local-side disconnect is in flight.
  disconnecting,

  /// Most recent connect attempt failed.
  failed,
}

/// Immutable view model for one row in the peers list.
///
/// Keyed by [BleAddress] until [nodeId] is known, then by [nodeId].
/// The [everConnected] flag is used by the prune-on-stop rule: when
/// discovery stops, peers that have not reached [DiscoveredPeerStatus.connected]
/// at any point during this session are evicted.
@immutable
class DiscoveredPeer {
  final BleAddress address;
  final NodeId? nodeId;
  final String? displayName;
  final int? rssi;
  final DateTime lastSeenAt;
  final DiscoveredPeerStatus status;
  final bool everConnected;

  const DiscoveredPeer({
    required this.address,
    required this.lastSeenAt,
    required this.status,
    this.nodeId,
    this.displayName,
    this.rssi,
    this.everConnected = false,
  });

  DiscoveredPeer copyWith({
    BleAddress? address,
    NodeId? nodeId,
    String? displayName,
    int? rssi,
    DateTime? lastSeenAt,
    DiscoveredPeerStatus? status,
    bool? everConnected,
  }) =>
      DiscoveredPeer(
        address: address ?? this.address,
        nodeId: nodeId ?? this.nodeId,
        displayName: displayName ?? this.displayName,
        rssi: rssi ?? this.rssi,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        status: status ?? this.status,
        everConnected: everConnected ?? this.everConnected,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredPeer &&
          address == other.address &&
          nodeId == other.nodeId &&
          displayName == other.displayName &&
          rssi == other.rssi &&
          lastSeenAt == other.lastSeenAt &&
          status == other.status &&
          everConnected == other.everConnected;

  @override
  int get hashCode => Object.hash(
        address,
        nodeId,
        displayName,
        rssi,
        lastSeenAt,
        status,
        everConnected,
      );

  @override
  String toString() => 'DiscoveredPeer('
      'address: $address, '
      'nodeId: $nodeId, '
      'displayName: $displayName, '
      'rssi: ${rssi != null ? '$rssi dBm' : 'null'}, '
      'lastSeenAt: $lastSeenAt, '
      'status: $status, '
      'everConnected: $everConnected'
      ')';
}
