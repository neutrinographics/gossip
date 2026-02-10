import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_local_node_repository.dart';

void main() {
  group('InMemoryLocalNodeRepository', () {
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
  });
}
