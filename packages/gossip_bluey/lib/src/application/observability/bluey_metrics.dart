/// Counters for monitoring `BlueyTransport` health and throughput.
class BlueyMetrics {
  int _connectedPeerCount = 0;
  int _totalConnectionsEstablished = 0;
  int _totalConnectionsFailed = 0;
  int _totalBytesSent = 0;
  int _totalBytesReceived = 0;
  int _totalMessagesSent = 0;
  int _totalMessagesReceived = 0;
  int _totalFramesSent = 0;
  int _totalFramesReceived = 0;

  int get connectedPeerCount => _connectedPeerCount;
  int get totalConnectionsEstablished => _totalConnectionsEstablished;
  int get totalConnectionsFailed => _totalConnectionsFailed;
  int get totalBytesSent => _totalBytesSent;
  int get totalBytesReceived => _totalBytesReceived;
  int get totalMessagesSent => _totalMessagesSent;
  int get totalMessagesReceived => _totalMessagesReceived;
  int get totalFramesSent => _totalFramesSent;
  int get totalFramesReceived => _totalFramesReceived;

  void setConnectedPeerCount(int n) => _connectedPeerCount = n;
  void recordConnectionEstablished() => _totalConnectionsEstablished++;
  void recordConnectionFailed() => _totalConnectionsFailed++;
  void recordBytesSent(int n) => _totalBytesSent += n;
  void recordBytesReceived(int n) => _totalBytesReceived += n;
  void recordMessageSent() => _totalMessagesSent++;
  void recordMessageReceived() => _totalMessagesReceived++;
  void recordFrameSent() => _totalFramesSent++;
  void recordFrameReceived() => _totalFramesReceived++;
}
