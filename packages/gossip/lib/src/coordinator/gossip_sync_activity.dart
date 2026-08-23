/// A coarse snapshot of gossip synchronization activity.
///
/// Lets an application show a "syncing…" vs "up to date" indicator without
/// the library retaining full per-peer digest state. Obtain it via
/// [Coordinator.gossipSyncActivity].
///
/// ## Interpreting the signal
///
/// - [outstandingPulls] > 0 means the node is actively pulling data from a
///   peer right now — show "syncing…".
/// - [isQuiescent] (no pulls in flight) together with a [mergedBatches] value
///   that has stopped advancing over a short window indicates the node has
///   caught up — show "up to date". The window/debounce is left to the app,
///   since only it knows what cadence feels right for its UI.
///
/// This is deliberately coarse: the library cannot prove global convergence
/// (it recomputes digests on demand rather than caching peers' last-advertised
/// versions), so treat this as a UX hint, not a consistency guarantee.
class GossipSyncActivity {
  /// Number of delta requests currently in flight (responses we are awaiting).
  final int outstandingPulls;

  /// Monotonic count of delta batches that merged at least one new entry
  /// since the gossip engine started. Poll it to detect recent activity.
  final int mergedBatches;

  const GossipSyncActivity({
    required this.outstandingPulls,
    required this.mergedBatches,
  });

  /// True when no pulls are in flight. Combine with a stable [mergedBatches]
  /// over time to infer the node is caught up.
  bool get isQuiescent => outstandingPulls == 0;

  @override
  bool operator ==(Object other) =>
      other is GossipSyncActivity &&
      other.outstandingPulls == outstandingPulls &&
      other.mergedBatches == mergedBatches;

  @override
  int get hashCode => Object.hash(outstandingPulls, mergedBatches);

  @override
  String toString() =>
      'GossipSyncActivity(outstandingPulls: $outstandingPulls, '
      'mergedBatches: $mergedBatches)';
}
