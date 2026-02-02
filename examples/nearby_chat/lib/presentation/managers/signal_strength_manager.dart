import 'package:gossip/gossip.dart' as gossip;

/// Manages signal strength smoothing for peers using a decay-based penalty system.
///
/// ## Algorithm Overview
///
/// The signal strength indicator uses a penalty-based smoothing algorithm to
/// provide stable, meaningful feedback about connection quality. Rather than
/// displaying raw probe failure counts (which can spike suddenly and recover
/// instantly), this algorithm applies gradual changes that better reflect
/// the user's perception of connection stability.
///
/// ## How It Works
///
/// 1. **Penalty Accumulation**: When a probe failure is detected (failedProbeCount
///    increases), the penalty increases by [penaltyIncrement] (0.4).
///
/// 2. **Gradual Decay**: Every update interval (2 seconds), all penalties decay
///    by [decayRate] (0.1). This means a single failure takes ~8 seconds to
///    fully recover (0.4 / 0.1 = 4 decay cycles × 2 seconds).
///
/// 3. **Thresholds**: The continuous penalty (0.0-1.0) is mapped to discrete
///    signal levels for display:
///    - penalty < 0.3: Excellent (0 bars lost) - full signal
///    - penalty < 0.6: Fair (1 bar lost) - minor degradation
///    - penalty >= 0.6: Poor (2 bars lost) - significant issues
///
/// ## Design Rationale
///
/// - **Stability**: Prevents UI flickering from transient network glitches
/// - **Responsiveness**: Multiple failures in quick succession accumulate,
///   providing faster feedback for real connection problems
/// - **Recovery**: Gradual decay ensures the indicator doesn't snap back
///   instantly, which would undermine user trust in the signal display
///
/// ## Constants
///
/// The constants are tuned for a balance between responsiveness and stability:
/// - [penaltyIncrement] = 0.4: Two consecutive failures reach "poor" status
/// - [decayRate] = 0.1: ~8 seconds to fully recover from one failure
/// - [lowThreshold] = 0.3: Tolerates brief glitches before showing degradation
/// - [mediumThreshold] = 0.6: Requires sustained issues for "poor" status
class SignalStrengthManager {
  /// Penalty increase per probe failure.
  static const double penaltyIncrement = 0.4;

  /// Penalty decrease per decay interval.
  static const double decayRate = 0.1;

  /// Penalty threshold below which signal is considered excellent (0 bars lost).
  static const double lowThreshold = 0.3;

  /// Penalty threshold below which signal is considered fair (1 bar lost).
  static const double mediumThreshold = 0.6;

  /// Current penalty values per peer (0.0 = excellent, 1.0 = poor).
  final Map<gossip.NodeId, double> _penalties = {};

  /// Last known failedProbeCount per peer, to detect increases.
  final Map<gossip.NodeId, int> _lastFailedCounts = {};

  /// Updates the penalty for a peer based on current failed probe count.
  ///
  /// Only increases penalty when [currentFailedCount] is greater than
  /// the previously recorded count for this peer.
  void updatePenalty(gossip.NodeId peerId, int currentFailedCount) {
    final lastCount = _lastFailedCounts[peerId] ?? 0;

    if (currentFailedCount > lastCount) {
      // Probe failed - increase penalty
      final currentPenalty = _penalties[peerId] ?? 0.0;
      _penalties[peerId] = (currentPenalty + penaltyIncrement).clamp(0.0, 1.0);
    }

    _lastFailedCounts[peerId] = currentFailedCount;
  }

  /// Decays all penalties by [decayRate].
  ///
  /// Returns true if any penalties were changed, false if no penalties exist.
  bool decayPenalties() {
    if (_penalties.isEmpty) return false;

    final toRemove = <gossip.NodeId>[];

    for (final entry in _penalties.entries) {
      final newPenalty = entry.value - decayRate;
      if (newPenalty <= 0) {
        toRemove.add(entry.key);
      } else {
        _penalties[entry.key] = newPenalty;
      }
    }

    for (final id in toRemove) {
      _penalties.remove(id);
    }

    return true;
  }

  /// Gets the smoothed failed probe count for display purposes.
  ///
  /// Maps the internal penalty to a discrete probe count:
  /// - 0: penalty < [lowThreshold]
  /// - 1: penalty < [mediumThreshold]
  /// - 2: penalty >= [mediumThreshold]
  int getSmoothedFailedProbeCount(gossip.NodeId peerId) {
    final penalty = _penalties[peerId] ?? 0.0;
    if (penalty < lowThreshold) return 0;
    if (penalty < mediumThreshold) return 1;
    return 2;
  }

  /// Clears all tracking data for a specific peer.
  void clearPeer(gossip.NodeId peerId) {
    _penalties.remove(peerId);
    _lastFailedCounts.remove(peerId);
  }

  /// Clears all tracking data for all peers.
  void clearAll() {
    _penalties.clear();
    _lastFailedCounts.clear();
  }

  /// Disposes of any resources.
  void dispose() {
    clearAll();
  }
}
