import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/domain/entities/connection_handle.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';

void main() {
  final nodeIdA = NodeId('11111111-1111-1111-1111-111111111111');
  final nodeIdB = NodeId('22222222-2222-2222-2222-222222222222');
  final t0 = DateTime(2026, 5, 4);

  ConnectionHandle handle(NodeId id, [ConnectionRole role = ConnectionRole.central]) =>
      ConnectionHandle(nodeId: id, role: role, connectedAt: t0);

  group('ConnectionRegistry', () {
    test('starts empty', () {
      final r = ConnectionRegistry();
      expect(r.connectionCount, equals(0));
      expect(r.connections, isEmpty);
      expect(r.contains(nodeIdA), isFalse);
    });

    test('add stores a handle and contains/get find it', () {
      final r = ConnectionRegistry();
      r.add(handle(nodeIdA));
      expect(r.contains(nodeIdA), isTrue);
      expect(r.get(nodeIdA), equals(handle(nodeIdA)));
      expect(r.connectionCount, equals(1));
    });

    test('add returns the previous handle if a duplicate exists', () {
      final r = ConnectionRegistry();
      final first = handle(nodeIdA, ConnectionRole.central);
      final second = handle(nodeIdA, ConnectionRole.peripheral);
      expect(r.add(first), isNull);
      final replaced = r.add(second);
      expect(replaced, equals(first));
      // The new handle is now stored.
      expect(r.get(nodeIdA)?.role, equals(ConnectionRole.peripheral));
    });

    test('remove returns the removed handle', () {
      final r = ConnectionRegistry();
      r.add(handle(nodeIdA));
      final removed = r.remove(nodeIdA);
      expect(removed, isNotNull);
      expect(r.contains(nodeIdA), isFalse);
      expect(r.connectionCount, equals(0));
    });

    test('remove of an absent NodeId returns null', () {
      final r = ConnectionRegistry();
      expect(r.remove(nodeIdA), isNull);
    });

    test('connections returns all handles', () {
      final r = ConnectionRegistry()
        ..add(handle(nodeIdA))
        ..add(handle(nodeIdB));
      expect(r.connections.map((h) => h.nodeId), containsAll([nodeIdA, nodeIdB]));
    });
  });
}
