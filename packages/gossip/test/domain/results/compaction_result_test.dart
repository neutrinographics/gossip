import 'package:test/test.dart';
import 'package:gossip/src/domain/results/compaction_result.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';

void main() {
  group('CompactionResult', () {
    final node1 = NodeId('node-1');
    final oldVersion = VersionVector({node1: 10});
    final newVersion = VersionVector({node1: 15});

    test(
      'CompactionResult.noChange returns zero counts with given version',
      () {
        final result = CompactionResult.noChange(oldVersion);

        expect(result.entriesRemoved, equals(0));
        expect(result.entriesRetained, equals(0));
        expect(result.bytesFreed, equals(0));
        expect(result.oldBaseVersion, equals(oldVersion));
        expect(result.newBaseVersion, equals(oldVersion));
      },
    );

    test('contains entriesRemoved, entriesRetained, bytesFreed', () {
      final result = CompactionResult(
        entriesRemoved: 10,
        entriesRetained: 5,
        bytesFreed: 500,
        oldBaseVersion: oldVersion,
        newBaseVersion: newVersion,
      );

      expect(result.entriesRemoved, equals(10));
      expect(result.entriesRetained, equals(5));
      expect(result.bytesFreed, equals(500));
    });

    test('contains oldBaseVersion and newBaseVersion', () {
      final result = CompactionResult(
        entriesRemoved: 10,
        entriesRetained: 5,
        bytesFreed: 500,
        oldBaseVersion: oldVersion,
        newBaseVersion: newVersion,
      );

      expect(result.oldBaseVersion, equals(oldVersion));
      expect(result.newBaseVersion, equals(newVersion));
    });

    test('equality works correctly', () {
      final result1 = CompactionResult(
        entriesRemoved: 10,
        entriesRetained: 5,
        bytesFreed: 500,
        oldBaseVersion: oldVersion,
        newBaseVersion: newVersion,
      );
      final result2 = CompactionResult(
        entriesRemoved: 10,
        entriesRetained: 5,
        bytesFreed: 500,
        oldBaseVersion: oldVersion,
        newBaseVersion: newVersion,
      );

      expect(result1, equals(result2));
    });

    test('hashCode is consistent with equality', () {
      final result1 = CompactionResult(
        entriesRemoved: 10,
        entriesRetained: 5,
        bytesFreed: 500,
        oldBaseVersion: oldVersion,
        newBaseVersion: newVersion,
      );
      final result2 = CompactionResult(
        entriesRemoved: 10,
        entriesRetained: 5,
        bytesFreed: 500,
        oldBaseVersion: oldVersion,
        newBaseVersion: newVersion,
      );

      expect(result1.hashCode, equals(result2.hashCode));
    });
  });
}
