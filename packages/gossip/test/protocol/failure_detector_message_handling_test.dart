import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/events/domain_event.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/protocol/failure_detector.dart';
import 'package:gossip/src/protocol/messages/ping.dart';
import 'package:gossip/src/protocol/messages/ack.dart';
import 'package:test/test.dart';

void main() {
  FailureDetector createDetector(
    NodeId localNode,
    PeerRegistry peerRegistry, {
    int? failureThreshold,
  }) {
    final timer = InMemoryTimePort();
    final bus = InMemoryMessageBus();
    final messagePort = InMemoryMessagePort(localNode, bus);
    return FailureDetector(
      localNode: localNode,
      peerRegistry: peerRegistry,
      timePort: timer,
      messagePort: messagePort,
      failureThreshold: failureThreshold ?? 3,
    );
  }

  group('FailureDetector message handling', () {
    test('handlePing returns an Ack with matching sequence', () {
      final localNode = NodeId('local');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final detector = createDetector(localNode, peerRegistry);

      final sender = NodeId('peer1');
      final ping = Ping(sender: sender, sequence: 42);

      final ack = detector.handlePing(ping);

      expect(ack.sender, equals(localNode));
      expect(ack.sequence, equals(42));
    });

    test('handleAck updates peer last contact time', () {
      final localNode = NodeId('local');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final detector = createDetector(localNode, peerRegistry);

      // Add a peer
      final peerId = NodeId('peer1');
      final now = DateTime.now();
      peerRegistry.addPeer(peerId, occurredAt: now);

      // Get initial last contact time
      final peerBefore = peerRegistry.getPeer(peerId);
      final initialContact = peerBefore!.lastContactMs;

      // Handle ack with later timestamp
      final laterMs = now.millisecondsSinceEpoch + 100;
      final ack = Ack(sender: peerId, sequence: 1);
      detector.handleAck(ack, timestampMs: laterMs);

      // Verify last contact time was updated
      final peerAfter = peerRegistry.getPeer(peerId);
      expect(peerAfter!.lastContactMs, equals(laterMs));
      expect(peerAfter.lastContactMs, greaterThan(initialContact));
    });

    test('recordProbeFailure increments failed probe count', () {
      final localNode = NodeId('local');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final detector = createDetector(localNode, peerRegistry);

      // Add a peer
      final peerId = NodeId('peer1');
      peerRegistry.addPeer(peerId, occurredAt: DateTime.now());

      // Get initial failed probe count
      final peerBefore = peerRegistry.getPeer(peerId);
      expect(peerBefore!.failedProbeCount, equals(0));

      // Record a probe failure
      detector.recordProbeFailure(peerId);

      // Verify failed probe count was incremented
      final peerAfter = peerRegistry.getPeer(peerId);
      expect(peerAfter!.failedProbeCount, equals(1));
    });

    test('checkPeerHealth marks peer as suspected after failure threshold', () {
      final localNode = NodeId('local');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final detector = createDetector(
        localNode,
        peerRegistry,
        failureThreshold: 3,
      );

      // Add a peer
      final peerId = NodeId('peer1');
      peerRegistry.addPeer(peerId, occurredAt: DateTime.now());

      // Record 3 failures
      detector.recordProbeFailure(peerId);
      detector.recordProbeFailure(peerId);
      detector.recordProbeFailure(peerId);

      // Check health
      detector.checkPeerHealth(peerId, occurredAt: DateTime.now());

      // Verify peer is marked as suspected
      final peer = peerRegistry.getPeer(peerId);
      expect(peer!.status, equals(PeerStatus.suspected));
    });
  });
}
