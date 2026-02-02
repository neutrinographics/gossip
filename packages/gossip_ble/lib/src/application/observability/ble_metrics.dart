/// Metrics for monitoring BLE transport.
///
/// ## Metric Semantics
///
/// Connection lifecycle metrics:
/// - [totalConnectionsEstablished]: Low-level BLE connections established
/// - [totalHandshakesCompleted]: Successful application-level handshakes
/// - [totalHandshakesFailed]: Failed handshakes (timeout, invalid data, etc.)
///
/// The relationship: `established = completed + failed + pending`
///
/// ## Usage
///
/// Call the `record*` methods in the following order for a successful connection:
/// 1. `recordConnectionEstablished()` - BLE connection established
/// 2. `recordHandshakeStarted()` - Handshake begins
/// 3. `recordHandshakeCompleted()` - Handshake succeeds
///
/// For a failed connection:
/// 1. `recordConnectionEstablished()` - BLE connection established
/// 2. `recordHandshakeStarted()` - Handshake begins
/// 3. `recordHandshakeFailed()` - Handshake fails (timeout, invalid, etc.)
class BleMetrics {
  int _connectedPeerCount = 0;
  int _pendingHandshakeCount = 0;
  int _totalConnectionsEstablished = 0;
  int _totalHandshakesCompleted = 0;
  int _totalHandshakesFailed = 0;
  int _totalBytesSent = 0;
  int _totalBytesReceived = 0;
  int _totalMessagesSent = 0;
  int _totalMessagesReceived = 0;

  final List<Duration> _handshakeDurations = [];

  /// Number of currently connected peers (handshake completed).
  int get connectedPeerCount => _connectedPeerCount;

  /// Number of handshakes in progress.
  int get pendingHandshakeCount => _pendingHandshakeCount;

  /// Total number of low-level BLE connections established.
  ///
  /// This counts all connections before handshake, including those that
  /// subsequently fail during the handshake phase.
  int get totalConnectionsEstablished => _totalConnectionsEstablished;

  /// Total number of successful application-level connections.
  ///
  /// A connection is considered successful when the handshake completes
  /// and NodeIds have been exchanged.
  int get totalHandshakesCompleted => _totalHandshakesCompleted;

  /// Total number of failed handshake attempts.
  ///
  /// This includes timeouts, invalid handshake data, and send failures.
  int get totalHandshakesFailed => _totalHandshakesFailed;

  /// Alias for [totalHandshakesFailed] for backwards compatibility.
  @Deprecated('Use totalHandshakesFailed instead')
  int get totalConnectionsFailed => _totalHandshakesFailed;

  /// Total bytes sent across all connections.
  int get totalBytesSent => _totalBytesSent;

  /// Total bytes received across all connections.
  int get totalBytesReceived => _totalBytesReceived;

  /// Total messages sent across all connections.
  int get totalMessagesSent => _totalMessagesSent;

  /// Total messages received across all connections.
  int get totalMessagesReceived => _totalMessagesReceived;

  /// Average time to complete handshake.
  Duration get averageHandshakeDuration {
    if (_handshakeDurations.isEmpty) return Duration.zero;
    final totalMs = _handshakeDurations.fold<int>(
      0,
      (sum, d) => sum + d.inMilliseconds,
    );
    return Duration(milliseconds: totalMs ~/ _handshakeDurations.length);
  }

  /// Records that a low-level BLE connection was established.
  ///
  /// Call this when the underlying BLE connection is established,
  /// before the application-level handshake begins.
  void recordConnectionEstablished() {
    _totalConnectionsEstablished++;
  }

  /// Records that a handshake has started for a connection.
  ///
  /// Call this after [recordConnectionEstablished] when the handshake
  /// protocol begins (sending local NodeId).
  void recordHandshakeStarted() {
    _pendingHandshakeCount++;
  }

  /// Records that a handshake completed successfully.
  ///
  /// Call this when the remote NodeId has been received and validated.
  /// [duration] should be the time from handshake start to completion.
  void recordHandshakeCompleted(Duration duration) {
    _pendingHandshakeCount = (_pendingHandshakeCount - 1).clamp(0, 999999);
    _connectedPeerCount++;
    _totalHandshakesCompleted++;
    _handshakeDurations.add(duration);
  }

  /// Records that a handshake failed.
  ///
  /// Call this when a handshake fails due to timeout, invalid data,
  /// send failure, or disconnection during handshake.
  void recordHandshakeFailed() {
    _pendingHandshakeCount = (_pendingHandshakeCount - 1).clamp(0, 999999);
    _totalHandshakesFailed++;
  }

  /// Records that a peer disconnected.
  ///
  /// Call this only for peers that had completed handshake
  /// (i.e., were counted in [connectedPeerCount]).
  void recordDisconnection() {
    _connectedPeerCount = (_connectedPeerCount - 1).clamp(0, 999999);
  }

  /// Records bytes sent in a message.
  void recordBytesSent(int bytes) {
    _totalBytesSent += bytes;
    _totalMessagesSent++;
  }

  /// Records bytes received in a message.
  void recordBytesReceived(int bytes) {
    _totalBytesReceived += bytes;
    _totalMessagesReceived++;
  }
}
