/// Metrics for monitoring Nearby Connections transport.
class NearbyMetrics {
  int _connectedPeerCount = 0;
  int _pendingHandshakeCount = 0;
  int _totalConnectionsEstablished = 0;
  int _totalConnectionsFailed = 0;
  int _totalBytesSent = 0;
  int _totalBytesReceived = 0;
  int _totalMessagesSent = 0;
  int _totalMessagesReceived = 0;

  final List<Duration> _handshakeDurations = [];

  /// Number of currently connected peers.
  int get connectedPeerCount => _connectedPeerCount;

  /// Number of handshakes in progress.
  int get pendingHandshakeCount => _pendingHandshakeCount;

  /// Total number of connections successfully established.
  int get totalConnectionsEstablished => _totalConnectionsEstablished;

  /// Total number of connection attempts that failed.
  int get totalConnectionsFailed => _totalConnectionsFailed;

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

  // --- Internal update methods ---

  void recordConnectionEstablished() {
    _totalConnectionsEstablished++;
  }

  void recordConnectionFailed() {
    _totalConnectionsFailed++;
  }

  void recordHandshakeStarted() {
    _pendingHandshakeCount++;
  }

  void recordHandshakeCompleted(Duration duration) {
    _pendingHandshakeCount--;
    _connectedPeerCount++;
    _handshakeDurations.add(duration);
  }

  void recordHandshakeFailed() {
    _pendingHandshakeCount--;
    _totalConnectionsFailed++;
  }

  void recordDisconnection() {
    if (_connectedPeerCount > 0) {
      _connectedPeerCount--;
    }
  }

  void recordBytesSent(int bytes) {
    _totalBytesSent += bytes;
    _totalMessagesSent++;
  }

  void recordBytesReceived(int bytes) {
    _totalBytesReceived += bytes;
    _totalMessagesReceived++;
  }
}
