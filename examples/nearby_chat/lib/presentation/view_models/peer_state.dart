import 'package:gossip/gossip.dart' as gossip;

/// Connection status for a peer in the UI.
enum PeerConnectionStatus { connected, suspected, unreachable }

/// UI state for a connected peer.
class PeerState {
  final gossip.NodeId id;
  final String displayName;
  final PeerConnectionStatus status;

  const PeerState({
    required this.id,
    required this.displayName,
    required this.status,
  });

  PeerState copyWith({String? displayName, PeerConnectionStatus? status}) =>
      PeerState(
        id: id,
        displayName: displayName ?? this.displayName,
        status: status ?? this.status,
      );
}
