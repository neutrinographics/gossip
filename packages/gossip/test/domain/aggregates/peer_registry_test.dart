import 'dart:math';

import 'package:test/test.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
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

    group('Probing hold (startup grace period)', () {
      test('setProbingHold sets the hold timestamp', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
        );
        final peerId = NodeId('peer-1');
        registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));

        registry.setProbingHold(peerId, 10000);

        final peer = registry.getPeer(peerId);
        expect(peer!.probingHeldUntilMs, equals(10000));
      });

      test('clearProbingHold clears the hold timestamp', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
        );
        final peerId = NodeId('peer-1');
        registry.addPeer(peerId, occurredAt: DateTime(2024, 1, 1));
        registry.setProbingHold(peerId, 10000);

        registry.clearProbingHold(peerId);

        final peer = registry.getPeer(peerId);
        expect(peer!.probingHeldUntilMs, isNull);
      });

      test('selectRandomProbablePeer excludes peers with active hold', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
        );
        final peer1 = NodeId('peer-1');
        final peer2 = NodeId('peer-2');
        registry.addPeer(peer1, occurredAt: DateTime(2024, 1, 1));
        registry.addPeer(peer2, occurredAt: DateTime(2024, 1, 1));

        // Set hold on peer1 until time 10000
        registry.setProbingHold(peer1, 10000);

        // At time 5000, peer1 should be excluded
        final selectedPeers = <NodeId>{};
        for (var i = 0; i < 20; i++) {
          final peer = registry.selectRandomProbablePeer(
            _SeededRandom(i),
            nowMs: 5000,
          );
          if (peer != null) selectedPeers.add(peer.id);
        }

        expect(selectedPeers, contains(peer2));
        expect(selectedPeers, isNot(contains(peer1)));
      });

      test('selectRandomProbablePeer includes peers after hold expires', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
        );
        final peer1 = NodeId('peer-1');
        registry.addPeer(peer1, occurredAt: DateTime(2024, 1, 1));

        // Set hold on peer1 until time 10000
        registry.setProbingHold(peer1, 10000);

        // At time 15000 (after hold expires), peer1 should be included
        final peer = registry.selectRandomProbablePeer(
          _SeededRandom(0),
          nowMs: 15000,
        );

        expect(peer, isNotNull);
        expect(peer!.id, equals(peer1));
      });

      test('selectRandomProbablePeer includes peer at exact hold expiry', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
        );
        final peer1 = NodeId('peer-1');
        registry.addPeer(peer1, occurredAt: DateTime(2024, 1, 1));

        // Set hold on peer1 until time 10000
        registry.setProbingHold(peer1, 10000);

        // At time 10000 (exact expiry), peer1 should be included
        final peer = registry.selectRandomProbablePeer(
          _SeededRandom(0),
          nowMs: 10000,
        );

        expect(peer, isNotNull);
        expect(peer!.id, equals(peer1));
      });

      test('selectRandomProbablePeer includes peers without hold', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
        );
        final peer1 = NodeId('peer-1');
        registry.addPeer(peer1, occurredAt: DateTime(2024, 1, 1));

        // No hold set - peer should always be selectable
        final peer = registry.selectRandomProbablePeer(
          _SeededRandom(0),
          nowMs: 5000,
        );

        expect(peer, isNotNull);
        expect(peer!.id, equals(peer1));
      });

      test('selectRandomProbablePeer returns null when all peers held', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
        );
        final peer1 = NodeId('peer-1');
        final peer2 = NodeId('peer-2');
        registry.addPeer(peer1, occurredAt: DateTime(2024, 1, 1));
        registry.addPeer(peer2, occurredAt: DateTime(2024, 1, 1));

        // Hold all peers
        registry.setProbingHold(peer1, 10000);
        registry.setProbingHold(peer2, 10000);

        // At time 5000, no peers should be selectable
        final peer = registry.selectRandomProbablePeer(
          _SeededRandom(0),
          nowMs: 5000,
        );

        expect(peer, isNull);
      });

      test('setProbingHold emits PeerOperationSkipped for unknown peer', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
        );

        registry.setProbingHold(NodeId('unknown'), 10000);

        final events = registry.uncommittedEvents;
        expect(events.length, equals(1));
        expect(events.last, isA<PeerOperationSkipped>());
        final event = events.last as PeerOperationSkipped;
        expect(event.operation, equals('setProbingHold'));
      });

      test('clearProbingHold emits PeerOperationSkipped for unknown peer', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
        );

        registry.clearProbingHold(NodeId('unknown'));

        final events = registry.uncommittedEvents;
        expect(events.length, equals(1));
        expect(events.last, isA<PeerOperationSkipped>());
        final event = events.last as PeerOperationSkipped;
        expect(event.operation, equals('clearProbingHold'));
      });

      test('selectRandomProbablePeer ignores hold when nowMs not provided', () {
        final registry = PeerRegistry(
          localNode: NodeId('local'),
          initialIncarnation: 0,
        );
        final peer1 = NodeId('peer-1');
        registry.addPeer(peer1, occurredAt: DateTime(2024, 1, 1));

        // Set hold on peer1
        registry.setProbingHold(peer1, 10000);

        // When nowMs is null, hold is ignored (backwards compatibility)
        final peer = registry.selectRandomProbablePeer(_SeededRandom(0));

        expect(peer, isNotNull);
        expect(peer!.id, equals(peer1));
      });
    });
  });
}

/// Simple seeded random for deterministic tests.
class _SeededRandom implements Random {
  int _seed;

  _SeededRandom(this._seed);

  @override
  int nextInt(int max) {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return _seed % max;
  }

  @override
  double nextDouble() => nextInt(1 << 32) / (1 << 32);

  @override
  bool nextBool() => nextInt(2) == 0;
}
