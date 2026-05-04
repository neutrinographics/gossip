import 'package:gossip/gossip.dart';

/// Result of a discovery round: a peer found over BLE that hosts the
/// gossip service.
class DiscoveredPeer {
  final NodeId nodeId;
  const DiscoveredPeer({required this.nodeId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DiscoveredPeer && other.nodeId == nodeId);

  @override
  int get hashCode => nodeId.hashCode;
}
