import 'package:meta/meta.dart';

import 'package:gossip/src/shared/domain/value_objects/rtt_estimate.dart';

/// Tracks communication metrics for a peer over time.
///
/// [PeerMetrics] records message and byte counts for communication with a peer.
/// It maintains both lifetime totals and a sliding window for rate limiting.
/// Optionally tracks per-peer RTT estimates for adaptive timeout computation.
///
/// The library tracks these metrics but does not enforce policies. Applications
/// can use these metrics to implement their own rate limiting, throttling, or
/// monitoring logic.
///
/// Metrics tracked:
/// - **Lifetime totals**: Total messages and bytes sent/received
/// - **Sliding window**: Recent message count within a time window
/// - **RTT estimate**: Per-peer round-trip time for adaptive timeouts
///
/// Value object with immutable value semantics.
@immutable
class PeerMetrics {
  /// Total messages received from this peer (lifetime).
  final int messagesReceived;

  /// Total messages sent to this peer (lifetime).
  final int messagesSent;

  /// Total bytes received from this peer (lifetime).
  final int bytesReceived;

  /// Total bytes sent to this peer (lifetime).
  final int bytesSent;

  /// Start time of the current sliding window (milliseconds since epoch).
  final int windowStartMs;

  /// Number of messages received within the current sliding window.
  final int messagesInWindow;

  /// Per-peer RTT estimate, or null if no RTT samples have been recorded.
  ///
  /// Updated by [recordRttSample] using EWMA smoothing (RFC 6298).
  /// Used by the failure detector for per-peer probe timeouts.
  final RttEstimate? rttEstimate;

  /// Creates [PeerMetrics] with the given values, defaulting to zero.
  const PeerMetrics({
    this.messagesReceived = 0,
    this.messagesSent = 0,
    this.bytesReceived = 0,
    this.bytesSent = 0,
    this.windowStartMs = 0,
    this.messagesInWindow = 0,
    this.rttEstimate,
  });

  /// Returns a copy with the given fields replaced; omitted fields keep
  /// their current value.
  ///
  /// CAUTION: a `null` argument means "keep current value," not "clear
  /// it" — so [rttEstimate] can never be reset to null through this
  /// method once set. None of this class's own update methods needs that
  /// (each either preserves or replaces an estimate), so the gap is
  /// unexercised here; a caller that genuinely needs to clear it must use
  /// the constructor directly.
  PeerMetrics copyWith({
    int? messagesReceived,
    int? messagesSent,
    int? bytesReceived,
    int? bytesSent,
    int? windowStartMs,
    int? messagesInWindow,
    RttEstimate? rttEstimate,
  }) => PeerMetrics(
    messagesReceived: messagesReceived ?? this.messagesReceived,
    messagesSent: messagesSent ?? this.messagesSent,
    bytesReceived: bytesReceived ?? this.bytesReceived,
    bytesSent: bytesSent ?? this.bytesSent,
    windowStartMs: windowStartMs ?? this.windowStartMs,
    messagesInWindow: messagesInWindow ?? this.messagesInWindow,
    rttEstimate: rttEstimate ?? this.rttEstimate,
  );

  /// Records an RTT sample and returns updated metrics.
  ///
  /// If no prior samples exist, initializes the estimate with the sample
  /// as the first data point (per RFC 6298). Otherwise applies EWMA smoothing.
  PeerMetrics recordRttSample(Duration sample) {
    final isFirst = rttEstimate == null;
    final currentEstimate = rttEstimate ?? RttEstimate.initial();
    final updatedEstimate = currentEstimate.update(
      sample,
      isFirstSample: isFirst,
    );
    return copyWith(rttEstimate: updatedEstimate);
  }

  /// Records a received message and returns updated metrics.
  ///
  /// Increments message and byte counters. Updates the sliding window,
  /// resetting it if [windowDurationMs] has elapsed since [windowStartMs].
  ///
  /// Parameters:
  /// - [bytes]: Size of the received message in bytes
  /// - [nowMs]: Current time in milliseconds since epoch
  /// - [windowDurationMs]: Duration of the sliding window in milliseconds
  PeerMetrics recordReceived(int bytes, int nowMs, int windowDurationMs) {
    final inNewWindow =
        windowStartMs == 0 || nowMs - windowStartMs >= windowDurationMs;
    return copyWith(
      messagesReceived: messagesReceived + 1,
      bytesReceived: bytesReceived + bytes,
      windowStartMs: inNewWindow ? nowMs : windowStartMs,
      messagesInWindow: inNewWindow ? 1 : messagesInWindow + 1,
    );
  }

  /// Records a sent message and returns updated metrics.
  ///
  /// Increments message and byte send counters. Does not affect the
  /// sliding window (only received messages count toward the window).
  ///
  /// Parameters:
  /// - [bytes]: Size of the sent message in bytes
  PeerMetrics recordSent(int bytes) =>
      copyWith(messagesSent: messagesSent + 1, bytesSent: bytesSent + bytes);

  @override
  bool operator ==(Object other) =>
      other is PeerMetrics &&
      other.messagesReceived == messagesReceived &&
      other.messagesSent == messagesSent &&
      other.bytesReceived == bytesReceived &&
      other.bytesSent == bytesSent &&
      other.windowStartMs == windowStartMs &&
      other.messagesInWindow == messagesInWindow &&
      other.rttEstimate == rttEstimate;

  @override
  int get hashCode => Object.hash(
    messagesReceived,
    messagesSent,
    bytesReceived,
    bytesSent,
    windowStartMs,
    messagesInWindow,
    rttEstimate,
  );
}
