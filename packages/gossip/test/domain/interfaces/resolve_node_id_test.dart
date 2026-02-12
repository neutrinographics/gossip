import 'package:gossip/gossip.dart';
import 'package:test/test.dart';

void main() {
  group('resolveNodeId', () {
    test('generates and persists a node ID on first call', () async {
      final repo = InMemoryLocalNodeRepository();

      final nodeId = await repo.resolveNodeId();

      expect(nodeId.value, isNotEmpty);
      expect(await repo.getNodeId(), equals(nodeId));
    });

    test('returns persisted node ID on subsequent calls', () async {
      final repo = InMemoryLocalNodeRepository();

      final first = await repo.resolveNodeId();
      final second = await repo.resolveNodeId();

      expect(second, equals(first));
    });

    test('returns pre-seeded node ID without generating', () async {
      final seeded = NodeId('pre-seeded');
      final repo = InMemoryLocalNodeRepository(nodeId: seeded);

      final nodeId = await repo.resolveNodeId();

      expect(nodeId, equals(seeded));
    });
  });
}
