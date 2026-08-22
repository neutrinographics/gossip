import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/shared/domain/events/domain_event.dart';
import 'package:gossip/src/membership/domain/events/membership_events.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:test/test.dart';

void main() {
  group('PeerRegistry event lifecycle', () {
    late PeerRegistry registry;
    final localNode = NodeId('local');
    final unknown = NodeId('never-added');

    setUp(() {
      registry = PeerRegistry(localNode: localNode);
    });

    test(
      'telemetry recording for unknown peers does not accumulate events',
      () {
        // These fire once per incoming/outgoing MESSAGE. A removed peer
        // whose transport still delivers would grow the buffer without
        // bound (2 events per message with both engines subscribed).
        for (var i = 0; i < 100; i++) {
          registry.recordMessageReceived(unknown, 10, i, 10000);
          registry.recordMessageSent(unknown, 10);
          registry.recordPeerRtt(unknown, const Duration(milliseconds: 100));
          registry.updatePeerContact(unknown, i);
          registry.updatePeerAntiEntropy(unknown, i);
          registry.incrementFailedProbeCount(unknown);
        }

        expect(
          registry.uncommittedEvents,
          isEmpty,
          reason:
              'per-message telemetry no-ops are routine churn, not domain '
              'events — buffering one per message is an unbounded leak',
        );
      },
    );

    test('takeUncommittedEvents drains the buffer', () {
      registry.addPeer(NodeId('peer1'), occurredAt: DateTime.now());

      final drained = registry.takeUncommittedEvents();
      expect(drained.whereType<PeerAdded>().length, equals(1));
      expect(registry.uncommittedEvents, isEmpty);
      expect(registry.takeUncommittedEvents(), isEmpty);
    });

    test('with an onEvent sink, events forward immediately and do not '
        'buffer', () {
      final forwarded = <DomainEvent>[];
      final sinked = PeerRegistry(
        localNode: localNode,
        onEvent: forwarded.add,
      );

      sinked.addPeer(NodeId('peer1'), occurredAt: DateTime.now());
      sinked.updatePeerStatus(
        NodeId('peer1'),
        PeerStatus.suspected,
        occurredAt: DateTime.now(),
      );
      sinked.removePeer(NodeId('peer1'), occurredAt: DateTime.now());

      expect(forwarded.whereType<PeerAdded>().length, equals(1));
      expect(forwarded.whereType<PeerStatusChanged>().length, equals(1));
      expect(forwarded.whereType<PeerRemoved>().length, equals(1));
      expect(
        sinked.uncommittedEvents,
        isEmpty,
        reason: 'a long-lived registry with a sink must not also buffer',
      );
    });
  });
}
