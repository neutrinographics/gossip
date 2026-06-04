import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';
import 'package:gossip_chat/presentation/view_models/discovered_peer.dart';

void main() {
  final addr = BleAddress('AA:BB:CC:DD:EE:FF');
  final nodeId = NodeId('00000000-0000-0000-0000-000000000001');
  final t = DateTime.utc(2026, 6, 3, 12);

  group('DiscoveredPeer', () {
    test('exposes all fields', () {
      final peer = DiscoveredPeer(
        address: addr,
        nodeId: nodeId,
        displayName: 'Pixel 6a',
        rssi: -48,
        lastSeenAt: t,
        status: DiscoveredPeerStatus.connected,
      );
      expect(peer.address, addr);
      expect(peer.nodeId, nodeId);
      expect(peer.displayName, 'Pixel 6a');
      expect(peer.rssi, -48);
      expect(peer.lastSeenAt, t);
      expect(peer.status, DiscoveredPeerStatus.connected);
    });

    test('nodeId, displayName, rssi nullable; address/lastSeenAt/status required', () {
      final peer = DiscoveredPeer(
        address: addr,
        lastSeenAt: t,
        status: DiscoveredPeerStatus.discovered,
      );
      expect(peer.nodeId, isNull);
      expect(peer.displayName, isNull);
      expect(peer.rssi, isNull);
    });

    test('copyWith updates only the named fields', () {
      final peer = DiscoveredPeer(
        address: addr,
        lastSeenAt: t,
        status: DiscoveredPeerStatus.discovered,
      );
      final updated = peer.copyWith(
        status: DiscoveredPeerStatus.connecting,
        rssi: -42,
      );
      expect(updated.address, addr);
      expect(updated.status, DiscoveredPeerStatus.connecting);
      expect(updated.rssi, -42);
      expect(updated.lastSeenAt, t);
    });

    test('copyWith preserves nullable fields when not specified', () {
      final peer = DiscoveredPeer(
        address: addr,
        nodeId: nodeId,
        displayName: 'X',
        rssi: -50,
        lastSeenAt: t,
        status: DiscoveredPeerStatus.connected,
      );
      final updated = peer.copyWith(lastSeenAt: DateTime.utc(2026, 6, 4));
      expect(updated.nodeId, nodeId);
      expect(updated.displayName, 'X');
      expect(updated.rssi, -50);
    });

    test('value equality by all fields', () {
      final a = DiscoveredPeer(
        address: addr,
        nodeId: nodeId,
        displayName: 'X',
        rssi: -50,
        lastSeenAt: t,
        status: DiscoveredPeerStatus.connected,
      );
      final b = DiscoveredPeer(
        address: addr,
        nodeId: nodeId,
        displayName: 'X',
        rssi: -50,
        lastSeenAt: t,
        status: DiscoveredPeerStatus.connected,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('inequality on each field', () {
      final base = DiscoveredPeer(
        address: addr,
        nodeId: nodeId,
        displayName: 'X',
        rssi: -50,
        lastSeenAt: t,
        status: DiscoveredPeerStatus.connected,
      );
      expect(base.copyWith(status: DiscoveredPeerStatus.suspected), isNot(equals(base)));
      expect(base.copyWith(rssi: -49), isNot(equals(base)));
      expect(
        DiscoveredPeer(
          address: BleAddress('FF:FF:FF:FF:FF:FF'),
          lastSeenAt: t,
          status: DiscoveredPeerStatus.connected,
        ),
        isNot(equals(base)),
      );
    });
  });

  group('DiscoveredPeerStatus', () {
    test('has 7 expected values', () {
      expect(DiscoveredPeerStatus.values, hasLength(7));
      expect(DiscoveredPeerStatus.values, containsAll([
        DiscoveredPeerStatus.discovered,
        DiscoveredPeerStatus.connecting,
        DiscoveredPeerStatus.connected,
        DiscoveredPeerStatus.suspected,
        DiscoveredPeerStatus.unreachable,
        DiscoveredPeerStatus.disconnecting,
        DiscoveredPeerStatus.failed,
      ]));
    });
  });
}
