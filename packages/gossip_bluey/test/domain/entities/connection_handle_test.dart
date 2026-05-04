import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/entities/connection_handle.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';

void main() {
  final nodeId = NodeId('11111111-1111-1111-1111-111111111111');
  final t0 = DateTime(2026, 5, 4);

  group('ConnectionHandle', () {
    test('exposes nodeId, role, displayName, connectedAt', () {
      final h = ConnectionHandle(
        nodeId: nodeId,
        role: ConnectionRole.central,
        displayName: 'Phone-A',
        connectedAt: t0,
      );
      expect(h.nodeId, equals(nodeId));
      expect(h.role, equals(ConnectionRole.central));
      expect(h.displayName, equals('Phone-A'));
      expect(h.connectedAt, equals(t0));
    });

    test('equality by nodeId only', () {
      final a = ConnectionHandle(
        nodeId: nodeId,
        role: ConnectionRole.central,
        connectedAt: t0,
      );
      final b = ConnectionHandle(
        nodeId: nodeId,
        role: ConnectionRole.peripheral,
        connectedAt: DateTime(2026, 6, 1),
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
