import 'package:gossip/gossip.dart';

import '../interfaces/bluey_port.dart';

/// Per-peer connection metadata held in the registry.
///
/// Equality is by nodeId only — at most one handle per NodeId can exist
/// in the registry.
class ConnectionHandle {
  final NodeId nodeId;
  final ConnectionRole role;
  final String? displayName;
  final DateTime connectedAt;

  const ConnectionHandle({
    required this.nodeId,
    required this.role,
    required this.connectedAt,
    this.displayName,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConnectionHandle && other.nodeId == nodeId);

  @override
  int get hashCode => nodeId.hashCode;
}
