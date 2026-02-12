import 'package:test/test.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/entities/peer.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/events/domain_event.dart';

void main() {
  group('PeerRegistry', () {
    test('can be constructed with localNode and initialIncarnation', () {
      final localNode = NodeId('local');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );

      expect(registry.localNode, equals(localNode));
      expect(registry.localIncarnation, equals(0));
    });

    test('addPeer adds a peer', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
        initialIncarnation: 0,
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
        initialIncarnation: 0,
      );

      expect(
        () => registry.addPeer(localNode, occurredAt: DateTime(2024, 1, 1)),
        throwsA(isA<Exception>()),
      );
    });

    test('getPeer retrieves added peer', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
        initialIncarnation: 0,
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
        initialIncarnation: 0,
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
        initialIncarnation: 0,
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
        initialIncarnation: 0,
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
        initialIncarnation: 0,
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
        initialIncarnation: 0,
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

    test('incrementLocalIncarnation increases incarnation', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
        initialIncarnation: 0,
      );

      registry.incrementLocalIncarnation();

      expect(registry.localIncarnation, equals(1));
    });

    test('updatePeerContact updates lastContactMs', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
        initialIncarnation: 0,
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
        initialIncarnation: 0,
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
        initialIncarnation: 0,
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
        initialIncarnation: 0,
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
        initialIncarnation: 0,
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
        initialIncarnation: 0,
      );
      final peerId = NodeId('peer-1');

      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      expect(registry.uncommittedEvents.length, equals(1));
      expect(registry.uncommittedEvents.first, isA<PeerAdded>());
    });

    test('removePeer emits PeerRemoved event', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
        initialIncarnation: 0,
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
        initialIncarnation: 0,
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

    test('updatePeerIncarnation updates incarnation', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
        initialIncarnation: 0,
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

      registry.updatePeerIncarnation(peerId, 5);

      final peer = registry.getPeer(peerId);
      expect(peer!.incarnation, equals(5));
    });

    test('updatePeerIncarnation changes suspected peer to reachable', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
        initialIncarnation: 0,
      );
      final peerId = NodeId('peer-1');
      registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));
      registry.updatePeerStatus(
        peerId,
        PeerStatus.suspected,
        occurredAt: DateTime(2024, 1, 1),
      );

      registry.updatePeerIncarnation(peerId, 5);

      final peer = registry.getPeer(peerId);
      expect(peer!.status, equals(PeerStatus.reachable));
      expect(peer.incarnation, equals(5));
    });

    test('incrementFailedProbeCount increments the failed probe count', () {
      final registry = PeerRegistry(
        localNode: NodeId('local'),
        initialIncarnation: 0,
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
          initialIncarnation: 0,
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

      test('updatePeerContact emits PeerOperationSkipped for unknown peer', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
        );
        final unknownPeerId = NodeId('unknown');

        registry.updatePeerContact(unknownPeerId, 1000);

        final events = registry.uncommittedEvents;
        expect(events.length, equals(1));
        expect(events.last, isA<PeerOperationSkipped>());
        final event = events.last as PeerOperationSkipped;
        expect(event.peerId, equals(unknownPeerId));
        expect(event.operation, equals('updatePeerContact'));
      });

      test(
        'updatePeerAntiEntropy emits PeerOperationSkipped for unknown peer',
        () {
          final registry = PeerRegistry(
            localNode: NodeId('local'),
            initialIncarnation: 0,
          );
          final unknownPeerId = NodeId('unknown');

          registry.updatePeerAntiEntropy(unknownPeerId, 1000);

          final events = registry.uncommittedEvents;
          expect(events.length, equals(1));
          expect(events.last, isA<PeerOperationSkipped>());
          final event = events.last as PeerOperationSkipped;
          expect(event.peerId, equals(unknownPeerId));
          expect(event.operation, equals('updatePeerAntiEntropy'));
        },
      );

      test(
        'recordMessageReceived emits PeerOperationSkipped for unknown peer',
        () {
          final registry = PeerRegistry(
            localNode: NodeId('local'),
            initialIncarnation: 0,
          );
          final unknownPeerId = NodeId('unknown');

          registry.recordMessageReceived(unknownPeerId, 100, 1000, 60000);

          final events = registry.uncommittedEvents;
          expect(events.length, equals(1));
          expect(events.last, isA<PeerOperationSkipped>());
          final event = events.last as PeerOperationSkipped;
          expect(event.peerId, equals(unknownPeerId));
          expect(event.operation, equals('recordMessageReceived'));
        },
      );

      test('recordMessageSent emits PeerOperationSkipped for unknown peer', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
        );
        final unknownPeerId = NodeId('unknown');

        registry.recordMessageSent(unknownPeerId, 100);

        final events = registry.uncommittedEvents;
        expect(events.length, equals(1));
        expect(events.last, isA<PeerOperationSkipped>());
        final event = events.last as PeerOperationSkipped;
        expect(event.peerId, equals(unknownPeerId));
        expect(event.operation, equals('recordMessageSent'));
      });

      test(
        'updatePeerIncarnation emits PeerOperationSkipped for unknown peer',
        () {
          final registry = PeerRegistry(
            localNode: NodeId('local'),
            initialIncarnation: 0,
          );
          final unknownPeerId = NodeId('unknown');

          registry.updatePeerIncarnation(unknownPeerId, 5);

          final events = registry.uncommittedEvents;
          expect(events.length, equals(1));
          expect(events.last, isA<PeerOperationSkipped>());
          final event = events.last as PeerOperationSkipped;
          expect(event.peerId, equals(unknownPeerId));
          expect(event.operation, equals('updatePeerIncarnation'));
        },
      );

      test(
        'incrementFailedProbeCount emits PeerOperationSkipped for unknown peer',
        () {
          final registry = PeerRegistry(
            localNode: NodeId('local'),
            initialIncarnation: 0,
          );
          final unknownPeerId = NodeId('unknown');

          registry.incrementFailedProbeCount(unknownPeerId);

          final events = registry.uncommittedEvents;
          expect(events.length, equals(1));
          expect(events.last, isA<PeerOperationSkipped>());
          final event = events.last as PeerOperationSkipped;
          expect(event.peerId, equals(unknownPeerId));
          expect(event.operation, equals('incrementFailedProbeCount'));
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
          incarnation: 3,
          lastContactMs: 5000,
          failedProbeCount: 2,
        );

        final registry = PeerRegistry.reconstitute(
          localNode: localNode,
          localIncarnation: 7,
          peers: [peer1, peer2],
        );

        expect(registry.localNode, equals(localNode));
        expect(registry.localIncarnation, equals(7));
        expect(registry.peerCount, equals(2));
        expect(registry.getPeer(NodeId('peer-1')), equals(peer1));
        expect(registry.getPeer(NodeId('peer-2')), equals(peer2));
        expect(
          registry.getPeer(NodeId('peer-2'))!.status,
          equals(PeerStatus.suspected),
        );
        expect(registry.getPeer(NodeId('peer-2'))!.incarnation, equals(3));
      });

      test('emits no domain events', () {
        final registry = PeerRegistry.reconstitute(
          localNode: NodeId('local'),
          localIncarnation: 0,
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
          localIncarnation: 0,
          peers: [],
        );

        expect(registry.peerCount, equals(0));
        expect(registry.isKnown(NodeId('local')), isFalse);
      });

      test('reconstituted registry supports normal operations', () {
        final registry = PeerRegistry.reconstitute(
          localNode: NodeId('local'),
          localIncarnation: 5,
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

        // Can increment incarnation
        registry.incrementLocalIncarnation();
        expect(registry.localIncarnation, equals(6));

        // Events only from operations after reconstitution
        expect(registry.uncommittedEvents, hasLength(2));
        expect(registry.uncommittedEvents[0], isA<PeerAdded>());
        expect(registry.uncommittedEvents[1], isA<PeerStatusChanged>());
      });
    });

    group('recordPeerRtt', () {
      test('records RTT sample on known peer', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
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
          initialIncarnation: 0,
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

      test('emits PeerOperationSkipped for unknown peer', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
        );

        registry.recordPeerRtt(
          NodeId('unknown'),
          const Duration(milliseconds: 100),
        );

        expect(
          registry.uncommittedEvents,
          contains(isA<PeerOperationSkipped>()),
        );
      });

      test('does not affect other peers', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
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
