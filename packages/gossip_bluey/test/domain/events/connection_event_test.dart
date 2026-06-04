import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/events/connection_event.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';

void main() {
  group('ConnectionEvent', () {
    final nodeId = NodeId('11111111-1111-1111-1111-111111111111');
    const address = BleAddress('AA:BB:CC:DD:EE:01');

    test('PeerOpened carries nodeId, address, and displayName', () {
      final event = PeerOpened(
        nodeId: nodeId,
        address: address,
        displayName: 'Phone-A',
      );
      expect(event.nodeId, equals(nodeId));
      expect(event.address, equals(address));
      expect(event.displayName, equals('Phone-A'));
    });

    test('PeerOpened equality', () {
      final a = PeerOpened(
        nodeId: nodeId,
        address: address,
        displayName: 'Phone-A',
      );
      final b = PeerOpened(
        nodeId: nodeId,
        address: address,
        displayName: 'Phone-A',
      );
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
