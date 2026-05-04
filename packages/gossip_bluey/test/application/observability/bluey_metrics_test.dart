import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';

void main() {
  group('BlueyMetrics', () {
    test('starts with all counters at zero', () {
      final m = BlueyMetrics();
      expect(m.connectedPeerCount, equals(0));
      expect(m.totalConnectionsEstablished, equals(0));
      expect(m.totalConnectionsFailed, equals(0));
      expect(m.totalBytesSent, equals(0));
      expect(m.totalBytesReceived, equals(0));
      expect(m.totalMessagesSent, equals(0));
      expect(m.totalMessagesReceived, equals(0));
      expect(m.totalFramesSent, equals(0));
      expect(m.totalFramesReceived, equals(0));
    });

    test('record* methods increment the corresponding counter', () {
      final m = BlueyMetrics();
      m.recordConnectionEstablished();
      m.recordConnectionFailed();
      m.recordBytesSent(100);
      m.recordBytesReceived(200);
      m.recordMessageSent();
      m.recordMessageReceived();
      m.recordFrameSent();
      m.recordFrameReceived();
      m.setConnectedPeerCount(3);

      expect(m.totalConnectionsEstablished, equals(1));
      expect(m.totalConnectionsFailed, equals(1));
      expect(m.totalBytesSent, equals(100));
      expect(m.totalBytesReceived, equals(200));
      expect(m.totalMessagesSent, equals(1));
      expect(m.totalMessagesReceived, equals(1));
      expect(m.totalFramesSent, equals(1));
      expect(m.totalFramesReceived, equals(1));
      expect(m.connectedPeerCount, equals(3));
    });
  });
}
