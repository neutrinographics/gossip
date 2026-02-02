import 'package:test/test.dart';
import 'package:gossip/src/domain/entities/peer.dart';
import 'package:gossip/src/domain/entities/peer_metrics.dart';
import 'package:gossip/src/domain/events/domain_event.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';

void main() {
  group('Peer', () {
    final nodeId = NodeId('node-1');

    test('Peer has id, status, incarnation, lastContactMs, metrics', () {
      final peer = Peer(
        id: nodeId,
        status: PeerStatus.reachable,
        incarnation: 5,
        lastContactMs: 1000,
        lastAntiEntropyMs: 2000,
        failedProbeCount: 0,
        metrics: PeerMetrics(),
      );

      expect(peer.id, equals(nodeId));
      expect(peer.status, equals(PeerStatus.reachable));
      expect(peer.incarnation, equals(5));
      expect(peer.lastContactMs, equals(1000));
      expect(peer.lastAntiEntropyMs, equals(2000));
      expect(peer.failedProbeCount, equals(0));
      expect(peer.metrics, isA<PeerMetrics>());
    });

    test('Peer.copyWith creates new instance with specified changes', () {
      final peer = Peer(
        id: nodeId,
        status: PeerStatus.reachable,
        incarnation: 5,
        lastContactMs: 1000,
      );

      final updated = peer.copyWith(
        status: PeerStatus.suspected,
        incarnation: 6,
      );

      expect(updated.id, equals(nodeId));
      expect(updated.status, equals(PeerStatus.suspected));
      expect(updated.incarnation, equals(6));
      expect(updated.lastContactMs, equals(1000)); // Unchanged
    });

    test('Peer.copyWith preserves unchanged fields', () {
      final originalMetrics = PeerMetrics(messagesReceived: 10);
      final peer = Peer(
        id: nodeId,
        status: PeerStatus.reachable,
        lastContactMs: 1000,
        metrics: originalMetrics,
      );

      final updated = peer.copyWith(status: PeerStatus.suspected);

      expect(updated.metrics, equals(originalMetrics));
      expect(updated.lastContactMs, equals(1000));
    });

    test('default status is reachable', () {
      final peer = Peer(id: nodeId, status: PeerStatus.reachable);

      expect(peer.status, equals(PeerStatus.reachable));
    });

    test('default metrics is empty PeerMetrics', () {
      final peer = Peer(id: nodeId, status: PeerStatus.reachable);

      expect(peer.metrics, equals(PeerMetrics()));
    });
  });
}
