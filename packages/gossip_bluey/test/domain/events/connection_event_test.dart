import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/events/connection_event.dart';

void main() {
  group('ConnectionEvent', () {
    final nodeId = NodeId('11111111-1111-1111-1111-111111111111');

    test('PeerOpened carries nodeId and displayName', () {
      final event = PeerOpened(nodeId: nodeId, displayName: 'Phone-A');
      expect(event.nodeId, equals(nodeId));
      expect(event.displayName, equals('Phone-A'));
    });

    test('PeerOpened equality', () {
      final a = PeerOpened(nodeId: nodeId, displayName: 'Phone-A');
      final b = PeerOpened(nodeId: nodeId, displayName: 'Phone-A');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('PeerClosed carries nodeId and reason', () {
      final event = PeerClosed(nodeId: nodeId, reason: 'silent peer');
      expect(event.nodeId, equals(nodeId));
      expect(event.reason, equals('silent peer'));
    });
  });
}
