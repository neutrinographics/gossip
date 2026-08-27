import 'package:gossip/src/shared/domain/value_objects/node_id.dart';

/// Sync's own view of a gossip partner — deliberately NOT membership's
/// `Peer`. Carries exactly what partner selection and pacing read: an
/// identity to address, an RTT sample for adaptive-interval pacing, and a
/// recency timestamp for gossip-round suppression.
///
/// Produced by `PeerDirectory` (see `../interfaces/peer_directory.dart`),
/// sync's port onto membership's peer state.
class SyncPartner {
  const SyncPartner({
    required this.nodeId,
    this.smoothedRtt,
    this.lastAntiEntropyMs,
  });

  /// Identity of the partner, used to address messages to it.
  final NodeId nodeId;

  /// Smoothed round-trip-time estimate, or null if none has been observed
  /// yet. Feeds `GossipTimingPolicy`'s median-SRTT adaptive base interval
  /// (see `_adaptiveBaseInterval` in `../services/gossip_timing_policy.dart`).
  final Duration? smoothedRtt;

  /// Milliseconds-since-epoch of the last anti-entropy exchange with this
  /// partner, or null if there has never been one. Feeds the gossip round's
  /// recency-suppression filter.
  final int? lastAntiEntropyMs;
}
