import 'package:test/test.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/entities/peer.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/events/domain_event.dart';

void main() {
  group('PeerRegistry', () {
    test('can be constructed with localNode', () {
      final localNode = NodeId('local');
      final registry = PeerRegistry(
        localNode: localNode,
      );

      expect(registry.localNode, equals(localNode));
    });

    test('addPeer adds a peer', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');

      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      expect(registry.isKnown(peerId), isTrue);
      expect(registry.peerCount, equals(1));
    });

    test('addPeer throws when adding local node', () {
      final localNode = NodeId('local');
      final registry = PeerRegistry(
        localNode: localNode,
      );

      expect(
        () => registry.addPeer(localNode, occurredAt: DateTime(2024, 1, 1)),
        throwsA(isA<Exception>()),
      );
    });

    test('getPeer retrieves added peer', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      final peer = registry.getPeer(peerId);

      expect(peer, isNotNull);
      expect(peer!.id, equals(peerId));
    });

    test('removePeer removes a peer', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      registry.removePeer(peerId, occurredAt: DateTime(2024, 1, 1));

      expect(registry.isKnown(peerId), isFalse);
      expect(registry.peerCount, equals(0));
    });

    test('updatePeerStatus changes peer status', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      registry.updatePeerStatus(
        peerId,
        PeerStatus.suspected,
        occurredAt: DateTime(2024, 1, 1),
      );

      final peer = registry.getPeer(peerId);
      expect(peer!.status, equals(PeerStatus.suspected));
    });

    test('isReachable returns true for reachable peers', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      expect(registry.isReachable(peerId), isTrue);

      registry.updatePeerStatus(
        peerId,
        PeerStatus.suspected,
        occurredAt: DateTime(2024, 1, 1),
      );
      expect(registry.isReachable(peerId), isFalse);
    });

    test('allPeers returns all peers', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      registry.addPeer(NodeId('peer-1'), occurredAt: DateTime(2024, 1, 1));
      registry.addPeer(NodeId('peer-2'), occurredAt: DateTime(2024, 1, 1));

      final peers = registry.allPeers;

      expect(peers.length, equals(2));
      expect(peers.any((p) => p.id == NodeId('peer-1')), isTrue);
      expect(peers.any((p) => p.id == NodeId('peer-2')), isTrue);
    });

    test('reachablePeers filters by reachable status', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      registry.addPeer(NodeId('peer-1'), occurredAt: DateTime(2024, 1, 1));
      registry.addPeer(NodeId('peer-2'), occurredAt: DateTime(2024, 1, 1));
      registry.updatePeerStatus(
        NodeId('peer-2'),
        PeerStatus.suspected,
        occurredAt: DateTime(2024, 1, 1),
      );

      final reachable = registry.reachablePeers;

      expect(reachable.length, equals(1));
      expect(reachable.first.id, equals(NodeId('peer-1')));
    });

    test('unreachablePeers returns only unreachable peers', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      registry.addPeer(NodeId('peer-1'), occurredAt: DateTime(2024, 1, 1));
      registry.addPeer(NodeId('peer-2'), occurredAt: DateTime(2024, 1, 1));
      registry.addPeer(NodeId('peer-3'), occurredAt: DateTime(2024, 1, 1));
      // peer-2 → suspected
      registry.updatePeerStatus(
        NodeId('peer-2'),
        PeerStatus.suspected,
        occurredAt: DateTime(2024, 1, 1),
      );
      // peer-3 → suspected → unreachable
      registry.updatePeerStatus(
        NodeId('peer-3'),
        PeerStatus.suspected,
        occurredAt: DateTime(2024, 1, 1),
      );
      registry.updatePeerStatus(
        NodeId('peer-3'),
        PeerStatus.unreachable,
        occurredAt: DateTime(2024, 1, 1),
      );

      final unreachable = registry.unreachablePeers;

      expect(unreachable.length, equals(1));
      expect(unreachable.first.id, equals(NodeId('peer-3')));
    });

    test('updatePeerContact updates lastContactMs', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      registry.updatePeerContact(peerId, 5000);

      final peer = registry.getPeer(peerId);
      expect(peer!.lastContactMs, equals(5000));
    });

    test('updatePeerAntiEntropy updates lastAntiEntropyMs', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      registry.updatePeerAntiEntropy(peerId, 6000);

      final peer = registry.getPeer(peerId);
      expect(peer!.lastAntiEntropyMs, equals(6000));
    });

    test('recordMessageReceived updates peer metrics', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      registry.recordMessageReceived(peerId, 100, 1000, 5000);

      final peer = registry.getPeer(peerId);
      expect(peer!.metrics.messagesReceived, equals(1));
      expect(peer.metrics.bytesReceived, equals(100));
    });

    test('recordMessageSent updates peer metrics', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      registry.recordMessageSent(peerId, 150);

      final peer = registry.getPeer(peerId);
      expect(peer!.metrics.messagesSent, equals(1));
      expect(peer.metrics.bytesSent, equals(150));
    });

    test('getMetrics returns peer metrics', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));
      registry.recordMessageSent(peerId, 100);

      final metrics = registry.getMetrics(peerId);

      expect(metrics, isNotNull);
      expect(metrics!.messagesSent, equals(1));
    });

    test('addPeer emits PeerAdded event', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');

      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      expect(registry.uncommittedEvents.length, equals(1));
      expect(registry.uncommittedEvents.first, isA<PeerAdded>());
    });

    test('removePeer emits PeerRemoved event', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      registry.removePeer(peerId, occurredAt: DateTime(2024, 1, 2));

      expect(registry.uncommittedEvents.length, equals(2));
      expect(registry.uncommittedEvents.last, isA<PeerRemoved>());
    });

    test('updatePeerStatus emits PeerStatusChanged event', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      registry.updatePeerStatus(
        peerId,
        PeerStatus.suspected,
        occurredAt: DateTime(2024, 1, 2),
      );

      expect(registry.uncommittedEvents.length, equals(2));
      expect(registry.uncommittedEvents.last, isA<PeerStatusChanged>());
    });

    test('incrementFailedProbeCount increments the failed probe count', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      expect(registry.getPeer(peerId)!.failedProbeCount, equals(0));

      registry.incrementFailedProbeCount(peerId);

      expect(registry.getPeer(peerId)!.failedProbeCount, equals(1));
    });

    group('PeerOperationSkipped events', () {
      test('updatePeerStatus emits PeerOperationSkipped for unknown peer', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
        );
        final unknownPeerId = NodeId('unknown');

        registry.updatePeerStatus(
          unknownPeerId,
          PeerStatus.suspected,
          occurredAt: DateTime(2024, 1, 1),
        );

        final events = registry.uncommittedEvents;
        expect(events.length, equals(1));
        expect(events.last, isA<PeerOperationSkipped>());
        final event = events.last as PeerOperationSkipped;
        expect(event.peerId, equals(unknownPeerId));
        expect(event.operation, equals('updatePeerStatus'));
      });

      test('updatePeerContact on unknown peer is a silent no-op', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
        );

        registry.updatePeerContact(NodeId('unknown'), 1000);

        // Per-message telemetry: emitting an event for every message from
        // an unknown/removed peer would grow without bound.
        expect(registry.uncommittedEvents, isEmpty);
      });

      test('updatePeerAntiEntropy on unknown peer is a silent no-op', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
        );

        registry.updatePeerAntiEntropy(NodeId('unknown'), 1000);

        expect(registry.uncommittedEvents, isEmpty);
      });

      test('recordMessageReceived on unknown peer is a silent no-op', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
        );

        registry.recordMessageReceived(NodeId('unknown'), 100, 1000, 60000);

        expect(registry.uncommittedEvents, isEmpty);
      });

      test('recordMessageSent on unknown peer is a silent no-op', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
        );

        registry.recordMessageSent(NodeId('unknown'), 100);

        expect(registry.uncommittedEvents, isEmpty);
      });

      test(
        'incrementFailedProbeCount on unknown peer is a silent no-op',
        () {
          final registry = PeerRegistry(
            localNode: NodeId('local'),
          );

          registry.incrementFailedProbeCount(NodeId('unknown'));

          // Per-probe telemetry: no event for unknown peers.
          expect(registry.uncommittedEvents, isEmpty);
        },
      );
    });

    group('reconstitute', () {
      test('restores peers', () {
        final localNode = NodeId('local');
        final peer1 = Peer(id: NodeId('peer-1'), displayName: 'Peer 1');
        final peer2 = Peer(
          id: NodeId('peer-2'),
          status: PeerStatus.suspected,
          lastContactMs: 5000,
          failedProbeCount: 2,
        );

        final registry = PeerRegistry.reconstitute(
          localNode: localNode,
          peers: [peer1, peer2],
        );

        expect(registry.localNode, equals(localNode));
        expect(registry.peerCount, equals(2));
        expect(registry.getPeer(NodeId('peer-1')), equals(peer1));
        expect(registry.getPeer(NodeId('peer-2')), equals(peer2));
        expect(
          registry.getPeer(NodeId('peer-2'))!.status,
          equals(PeerStatus.suspected),
        );
      });

      test('emits no domain events', () {
        final registry = PeerRegistry.reconstitute(
          localNode: NodeId('local'),
          peers: [
            Peer(id: NodeId('peer-1')),
            Peer(id: NodeId('peer-2')),
          ],
        );

        expect(registry.uncommittedEvents, isEmpty);
      });

      test('does not auto-add localNode as a peer', () {
        final registry = PeerRegistry.reconstitute(
          localNode: NodeId('local'),
          peers: [],
        );

        expect(registry.peerCount, equals(0));
        expect(registry.isKnown(NodeId('local')), isFalse);
      });

      test('reconstituted registry supports normal operations', () {
        final registry = PeerRegistry.reconstitute(
          localNode: NodeId('local'),
          peers: [Peer(id: NodeId('peer-1'))],
        );

        // Can add a new peer
        registry.addPeer(NodeId('peer-3'), occurredAt: DateTime(2024, 1, 1));
        expect(registry.peerCount, equals(2));
        expect(registry.isKnown(NodeId('peer-3')), isTrue);

        // Can update existing peer status
        registry.updatePeerStatus(
          NodeId('peer-1'),
          PeerStatus.suspected,
          occurredAt: DateTime(2024, 1, 1),
        );
        expect(
          registry.getPeer(NodeId('peer-1'))!.status,
          equals(PeerStatus.suspected),
        );

        // Events only from operations after reconstitution
        expect(registry.uncommittedEvents, hasLength(2));
        expect(registry.uncommittedEvents[0], isA<PeerAdded>());
        expect(registry.uncommittedEvents[1], isA<PeerStatusChanged>());
      });
    });

    group('updatePeerContact event emission', () {
      test('emits PeerStatusChanged when recovering from suspected', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
        );
        final peerId = NodeId('peer-1');
        registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));
        registry.updatePeerStatus(
          peerId,
          PeerStatus.suspected,
          occurredAt: DateTime(2024, 1, 1),
        );

        final eventsBefore = registry.uncommittedEvents.length;

        registry.updatePeerContact(peerId, 5000);

        final newEvents = registry.uncommittedEvents
            .skip(eventsBefore)
            .toList();
        expect(newEvents, hasLength(1));
        expect(newEvents.first, isA<PeerStatusChanged>());
        final event = newEvents.first as PeerStatusChanged;
        expect(event.peerId, equals(peerId));
        expect(event.oldStatus, equals(PeerStatus.suspected));
        expect(event.newStatus, equals(PeerStatus.reachable));
      });

      test('emits PeerStatusChanged when recovering from unreachable', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
        );
        final peerId = NodeId('peer-1');
        registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));
        registry.updatePeerStatus(
          peerId,
          PeerStatus.suspected,
          occurredAt: DateTime(2024, 1, 1),
        );
        registry.updatePeerStatus(
          peerId,
          PeerStatus.unreachable,
          occurredAt: DateTime(2024, 1, 1),
        );

        final eventsBefore = registry.uncommittedEvents.length;

        registry.updatePeerContact(peerId, 5000);

        final newEvents = registry.uncommittedEvents
            .skip(eventsBefore)
            .toList();
        expect(newEvents, hasLength(1));
        expect(newEvents.first, isA<PeerStatusChanged>());
        final event = newEvents.first as PeerStatusChanged;
        expect(event.peerId, equals(peerId));
        expect(event.oldStatus, equals(PeerStatus.unreachable));
        expect(event.newStatus, equals(PeerStatus.reachable));
      });

      test('does not emit PeerStatusChanged when already reachable', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
        );
        final peerId = NodeId('peer-1');
        registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

        final eventsBefore = registry.uncommittedEvents.length;

        registry.updatePeerContact(peerId, 5000);

        final newEvents = registry.uncommittedEvents
            .skip(eventsBefore)
            .toList();
        expect(newEvents, isEmpty);
      });
    });

    group('recordPeerRtt', () {
      test('records RTT sample on known peer', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
        );
        final peerId = NodeId('peer1');
        registry.addPeer(peerId, occurredAt: DateTime.now());

        registry.recordPeerRtt(peerId, const Duration(milliseconds: 150));

        final peer = registry.getPeer(peerId)!;
        expect(peer.metrics.rttEstimate, isNotNull);
        expect(
          peer.metrics.rttEstimate!.smoothedRtt,
          equals(const Duration(milliseconds: 150)),
        );
      });

      test('accumulates multiple RTT samples', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
        );
        final peerId = NodeId('peer1');
        registry.addPeer(peerId, occurredAt: DateTime.now());

        registry.recordPeerRtt(peerId, const Duration(milliseconds: 100));
        registry.recordPeerRtt(peerId, const Duration(milliseconds: 200));

        final peer = registry.getPeer(peerId)!;
        expect(peer.metrics.rttEstimate, isNotNull);
        // EWMA: after first=100ms, second=200ms
        expect(
          peer.metrics.rttEstimate!.smoothedRtt.inMilliseconds,
          closeTo(112, 2),
        );
      });

      test('is a silent no-op for unknown peer', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
        );

        registry.recordPeerRtt(
          NodeId('unknown'),
          const Duration(milliseconds: 100),
        );

        // Per-probe telemetry: no event for unknown peers.
        expect(registry.uncommittedEvents, isEmpty);
      });

      test('does not affect other peers', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
        );
        final peer1 = NodeId('peer1');
        final peer2 = NodeId('peer2');
        registry.addPeer(peer1, occurredAt: DateTime.now());
        registry.addPeer(peer2, occurredAt: DateTime.now());

        registry.recordPeerRtt(peer1, const Duration(milliseconds: 150));

        expect(registry.getPeer(peer1)!.metrics.rttEstimate, isNotNull);
        expect(registry.getPeer(peer2)!.metrics.rttEstimate, isNull);
      });
    });
  });
}
