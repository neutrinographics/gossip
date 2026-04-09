import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/interfaces/local_node_repository.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_local_node_repository.dart';

void main() {
  group('InMemoryLocalNodeRepository', () {
    group('node ID', () {
      test('returns null initially when no nodeId provided', () async {
        final repository = InMemoryLocalNodeRepository();

        final nodeId = await repository.getNodeId();

        expect(nodeId, isNull);
      });

      test('returns provided nodeId from constructor', () async {
        final repository = InMemoryLocalNodeRepository(
          nodeId: NodeId('test-node'),
        );

        final nodeId = await repository.getNodeId();

        expect(nodeId, equals(NodeId('test-node')));
      });

      test('save and get round-trips nodeId', () async {
        final repository = InMemoryLocalNodeRepository();

        await repository.saveNodeId(NodeId('my-node'));
        final retrieved = await repository.getNodeId();

        expect(retrieved, equals(NodeId('my-node')));
      });

      test('generateNodeId returns a valid NodeId', () async {
        final repository = InMemoryLocalNodeRepository();

        final nodeId = await repository.generateNodeId();

        expect(nodeId.value, isNotEmpty);
      });

      test('generateNodeId returns unique values on each call', () async {
        final repository = InMemoryLocalNodeRepository();

        final id1 = await repository.generateNodeId();
        final id2 = await repository.generateNodeId();

        expect(id1, isNot(equals(id2)));
      });
    });

    group('clock state', () {
      test('returns Hlc.zero initially', () async {
        final repository = InMemoryLocalNodeRepository();

        final state = await repository.getClockState();

        expect(state, equals(Hlc.zero));
      });

      test('save and get round-trips clock state', () async {
        final repository = InMemoryLocalNodeRepository();
        final hlc = Hlc(5000, 42);

        await repository.saveClockState(hlc);
        final retrieved = await repository.getClockState();

        expect(retrieved, equals(hlc));
      });

      test('overwrites previous clock state', () async {
        final repository = InMemoryLocalNodeRepository();

        await repository.saveClockState(Hlc(1000, 1));
        await repository.saveClockState(Hlc(2000, 2));
        final retrieved = await repository.getClockState();

        expect(retrieved, equals(Hlc(2000, 2)));
      });
    });

    group('incarnation', () {
      test('returns 0 initially', () async {
        final repository = InMemoryLocalNodeRepository();

        final incarnation = await repository.getIncarnation();

        expect(incarnation, equals(0));
      });

      test('save and get round-trips incarnation', () async {
        final repository = InMemoryLocalNodeRepository();

        await repository.saveIncarnation(7);
        final retrieved = await repository.getIncarnation();

        expect(retrieved, equals(7));
      });

      test('overwrites previous incarnation', () async {
        final repository = InMemoryLocalNodeRepository();

        await repository.saveIncarnation(3);
        await repository.saveIncarnation(5);
        final retrieved = await repository.getIncarnation();

        expect(retrieved, equals(5));
      });
    });

    group('reset', () {
      test('clears node ID, clock state, and incarnation', () async {
        final repository = InMemoryLocalNodeRepository(
          nodeId: NodeId('test-node'),
        );
        await repository.saveClockState(Hlc(5000, 42));
        await repository.saveIncarnation(7);

        await repository.reset();

        expect(await repository.getNodeId(), isNull);
        expect(await repository.getClockState(), equals(Hlc.zero));
        expect(await repository.getIncarnation(), equals(0));
      });

      test('resolveNodeId generates new ID after reset', () async {
        final repository = InMemoryLocalNodeRepository(
          nodeId: NodeId('original-node'),
        );

        final originalId = await repository.resolveNodeId();
        expect(originalId.value, equals('original-node'));

        await repository.reset();

        final newId = await repository.resolveNodeId();
        expect(newId, isNot(equals(originalId)));
      });
    });
  });
}
