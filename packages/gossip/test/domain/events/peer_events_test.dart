import 'package:test/test.dart';
import 'package:gossip/src/domain/events/domain_event.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';

void main() {
  group('Peer Events', () {
    final peerId = NodeId('peer-1');
    final now = DateTime(2024, 1, 15, 12, 0, 0);

    group('PeerAdded', () {
      test('contains peerId and occurredAt', () {
        final event = PeerAdded(peerId, occurredAt: now);

        expect(event.peerId, equals(peerId));
        expect(event.occurredAt, equals(now));
      });
    });

    group('PeerRemoved', () {
      test('contains peerId and occurredAt', () {
        final event = PeerRemoved(peerId, occurredAt: now);

        expect(event.peerId, equals(peerId));
        expect(event.occurredAt, equals(now));
      });
    });

    group('PeerStatusChanged', () {
      test('contains peerId, oldStatus, newStatus, occurredAt', () {
        final event = PeerStatusChanged(
          peerId,
          PeerStatus.reachable,
          PeerStatus.suspected,
          occurredAt: now,
        );

        expect(event.peerId, equals(peerId));
        expect(event.oldStatus, equals(PeerStatus.reachable));
        expect(event.newStatus, equals(PeerStatus.suspected));
        expect(event.occurredAt, equals(now));
      });
    });
  });
}
