import 'package:test/test.dart';
import 'package:gossip/src/domain/entities/peer_metrics.dart';

void main() {
  group('PeerMetrics', () {
    test('default constructor creates empty metrics', () {
      final metrics = PeerMetrics();

      expect(metrics.messagesReceived, equals(0));
      expect(metrics.messagesSent, equals(0));
      expect(metrics.bytesReceived, equals(0));
      expect(metrics.bytesSent, equals(0));
      expect(metrics.windowStartMs, equals(0));
      expect(metrics.messagesInWindow, equals(0));
    });

    test('recordReceived increments counters', () {
      final metrics = PeerMetrics();
      final updated = metrics.recordReceived(100, 1000, 5000);

      expect(updated.messagesReceived, equals(1));
      expect(updated.bytesReceived, equals(100));
      expect(updated.windowStartMs, equals(1000));
      expect(updated.messagesInWindow, equals(1));
      // Sent counters unchanged
      expect(updated.messagesSent, equals(0));
      expect(updated.bytesSent, equals(0));
    });

    test('recordReceived accumulates within window', () {
      var metrics = PeerMetrics();
      metrics = metrics.recordReceived(100, 1000, 5000);
      metrics = metrics.recordReceived(200, 2000, 5000);

      expect(metrics.messagesReceived, equals(2));
      expect(metrics.bytesReceived, equals(300));
      expect(metrics.windowStartMs, equals(1000)); // Window not reset
      expect(metrics.messagesInWindow, equals(2));
    });

    test('recordReceived resets window after duration', () {
      var metrics = PeerMetrics();
      metrics = metrics.recordReceived(100, 1000, 5000);
      metrics = metrics.recordReceived(200, 6001, 5000); // Beyond 5000ms window

      expect(metrics.messagesReceived, equals(2));
      expect(metrics.bytesReceived, equals(300));
      expect(metrics.windowStartMs, equals(6001)); // Window reset
      expect(metrics.messagesInWindow, equals(1)); // Count reset
    });

    test('recordSent increments counters', () {
      final metrics = PeerMetrics();
      final updated = metrics.recordSent(150);

      expect(updated.messagesSent, equals(1));
      expect(updated.bytesSent, equals(150));
      // Received counters unchanged
      expect(updated.messagesReceived, equals(0));
      expect(updated.bytesReceived, equals(0));
    });

    test('recordSent accumulates', () {
      var metrics = PeerMetrics();
      metrics = metrics.recordSent(100);
      metrics = metrics.recordSent(200);

      expect(metrics.messagesSent, equals(2));
      expect(metrics.bytesSent, equals(300));
    });

    test('equality compares all fields', () {
      final metrics1 = PeerMetrics(
        messagesReceived: 5,
        messagesSent: 3,
        bytesReceived: 500,
        bytesSent: 300,
        windowStartMs: 1000,
        messagesInWindow: 2,
      );

      final metrics2 = PeerMetrics(
        messagesReceived: 5,
        messagesSent: 3,
        bytesReceived: 500,
        bytesSent: 300,
        windowStartMs: 1000,
        messagesInWindow: 2,
      );

      final metrics3 = PeerMetrics(
        messagesReceived: 6, // Different
        messagesSent: 3,
        bytesReceived: 500,
        bytesSent: 300,
        windowStartMs: 1000,
        messagesInWindow: 2,
      );

      expect(metrics1, equals(metrics2));
      expect(metrics1, isNot(equals(metrics3)));
    });

    test('hashCode is consistent', () {
      final metrics1 = PeerMetrics(
        messagesReceived: 5,
        messagesSent: 3,
        bytesReceived: 500,
        bytesSent: 300,
        windowStartMs: 1000,
        messagesInWindow: 2,
      );

      final metrics2 = PeerMetrics(
        messagesReceived: 5,
        messagesSent: 3,
        bytesReceived: 500,
        bytesSent: 300,
        windowStartMs: 1000,
        messagesInWindow: 2,
      );

      expect(metrics1.hashCode, equals(metrics2.hashCode));
    });
  });
}
