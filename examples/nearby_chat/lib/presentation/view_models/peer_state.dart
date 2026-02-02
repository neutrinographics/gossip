import 'package:gossip/gossip.dart' as gossip;

/// Connection status for a peer in the UI.
enum PeerConnectionStatus { connected, suspected, unreachable }

/// UI state for a connected peer.
class PeerState {
  final gossip.NodeId id;
  final String displayName;
  final PeerConnectionStatus status;

  /// Number of consecutive failed probes (0 = healthy connection).
  ///
  /// Used to display signal strength indicator:
  /// - 0 failures = 3 bars (excellent)
  /// - 1 failure = 2 bars (good)
  /// - 2+ failures = 1 bar (poor)
  final int failedProbeCount;

  const PeerState({
    required this.id,
    required this.displayName,
    required this.status,
    this.failedProbeCount = 0,
  });

  /// Signal strength from 1-3 based on failed probe count.
  int get signalStrength {
    if (failedProbeCount == 0) return 3;
    if (failedProbeCount == 1) return 2;
    return 1;
  }

  PeerState copyWith({
    String? displayName,
    PeerConnectionStatus? status,
    int? failedProbeCount,
  }) => PeerState(
    id: id,
    displayName: displayName ?? this.displayName,
    status: status ?? this.status,
    failedProbeCount: failedProbeCount ?? this.failedProbeCount,
  );
}
