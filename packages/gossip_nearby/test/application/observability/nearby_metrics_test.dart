import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_nearby/src/application/observability/nearby_metrics.dart';

void main() {
  group('NearbyMetrics', () {
    late NearbyMetrics metrics;

    setUp(() {
      metrics = NearbyMetrics();
    });

    group('initial state', () {
      test('all counters start at zero', () {
        expect(metrics.connectedPeerCount, equals(0));
        expect(metrics.pendingHandshakeCount, equals(0));
        expect(metrics.totalConnectionsEstablished, equals(0));
        expect(metrics.totalConnectionsFailed, equals(0));
        expect(metrics.totalBytesSent, equals(0));
        expect(metrics.totalBytesReceived, equals(0));
        expect(metrics.totalMessagesSent, equals(0));
        expect(metrics.totalMessagesReceived, equals(0));
        expect(metrics.averageHandshakeDuration, equals(Duration.zero));
      });
    });

    group('connection tracking', () {
      test('recordConnectionEstablished increments counter', () {
        metrics.recordConnectionEstablished();
        metrics.recordConnectionEstablished();

        expect(metrics.totalConnectionsEstablished, equals(2));
      });

      test('recordConnectionFailed increments counter', () {
        metrics.recordConnectionFailed();

        expect(metrics.totalConnectionsFailed, equals(1));
      });
    });

    group('handshake tracking', () {
      test('recordHandshakeStarted increments pending count', () {
        metrics.recordHandshakeStarted();
        metrics.recordHandshakeStarted();

        expect(metrics.pendingHandshakeCount, equals(2));
      });

      test('recordHandshakeCompleted updates counts and duration', () {
        metrics.recordHandshakeStarted();
        metrics.recordHandshakeCompleted(Duration(milliseconds: 100));

        expect(metrics.pendingHandshakeCount, equals(0));
        expect(metrics.connectedPeerCount, equals(1));
        expect(
          metrics.averageHandshakeDuration,
          equals(Duration(milliseconds: 100)),
        );
      });

      test(
        'recordHandshakeFailed decrements pending and increments failed',
        () {
          metrics.recordHandshakeStarted();
          metrics.recordHandshakeFailed();

          expect(metrics.pendingHandshakeCount, equals(0));
          expect(metrics.totalConnectionsFailed, equals(1));
        },
      );
    });

    group('disconnection tracking', () {
      test('recordDisconnection decrements connected count', () {
        metrics.recordHandshakeStarted();
        metrics.recordHandshakeCompleted(Duration.zero);
        metrics.recordDisconnection();

        expect(metrics.connectedPeerCount, equals(0));
      });

      test('recordDisconnection does not go below zero', () {
        metrics.recordDisconnection();

        expect(metrics.connectedPeerCount, equals(0));
      });
    });

    group('byte tracking', () {
      test('recordBytesSent tracks bytes and message count', () {
        metrics.recordBytesSent(100);
        metrics.recordBytesSent(50);

        expect(metrics.totalBytesSent, equals(150));
        expect(metrics.totalMessagesSent, equals(2));
      });

      test('recordBytesReceived tracks bytes and message count', () {
        metrics.recordBytesReceived(200);
        metrics.recordBytesReceived(100);
        metrics.recordBytesReceived(50);

        expect(metrics.totalBytesReceived, equals(350));
        expect(metrics.totalMessagesReceived, equals(3));
      });
    });

    group('averageHandshakeDuration', () {
      test('computes average across multiple handshakes', () {
        metrics.recordHandshakeStarted();
        metrics.recordHandshakeCompleted(Duration(milliseconds: 100));
        metrics.recordHandshakeStarted();
        metrics.recordHandshakeCompleted(Duration(milliseconds: 200));
        metrics.recordHandshakeStarted();
        metrics.recordHandshakeCompleted(Duration(milliseconds: 300));

        // (100 + 200 + 300) / 3 = 200
        expect(
          metrics.averageHandshakeDuration,
          equals(Duration(milliseconds: 200)),
        );
      });

      test('returns zero with no completed handshakes', () {
        expect(metrics.averageHandshakeDuration, equals(Duration.zero));
      });
    });
  });
}
