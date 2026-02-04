import '../value_objects/rtt_estimate.dart';

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
/// Entities are compared by value equality (immutable value semantics).
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
    return PeerMetrics(
      messagesReceived: messagesReceived,
      messagesSent: messagesSent,
      bytesReceived: bytesReceived,
      bytesSent: bytesSent,
      windowStartMs: windowStartMs,
      messagesInWindow: messagesInWindow,
      rttEstimate: updatedEstimate,
    );
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
    return PeerMetrics(
      messagesReceived: messagesReceived + 1,
      messagesSent: messagesSent,
      bytesReceived: bytesReceived + bytes,
      bytesSent: bytesSent,
      windowStartMs: inNewWindow ? nowMs : windowStartMs,
      messagesInWindow: inNewWindow ? 1 : messagesInWindow + 1,
      rttEstimate: rttEstimate,
    );
  }

  /// Records a sent message and returns updated metrics.
  ///
  /// Increments message and byte send counters. Does not affect the
  /// sliding window (only received messages count toward the window).
  ///
  /// Parameters:
  /// - [bytes]: Size of the sent message in bytes
  PeerMetrics recordSent(int bytes) => PeerMetrics(
    messagesReceived: messagesReceived,
    messagesSent: messagesSent + 1,
    bytesReceived: bytesReceived,
    bytesSent: bytesSent + bytes,
    windowStartMs: windowStartMs,
    messagesInWindow: messagesInWindow,
    rttEstimate: rttEstimate,
  );

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
