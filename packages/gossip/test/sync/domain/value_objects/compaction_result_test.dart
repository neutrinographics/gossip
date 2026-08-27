import 'package:test/test.dart';
import 'package:gossip/src/sync/domain/value_objects/compaction_result.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';

void main() {
  group('CompactionResult', () {
    final node1 = NodeId('node-1');
    final version = VersionVector({node1: 10});

    test('contains entriesRemoved, entriesRetained, bytesFreed', () {
      final result = CompactionResult(
        entriesRemoved: 10,
        entriesRetained: 5,
        bytesFreed: 500,
        baseVersion: version,
      );

      expect(result.entriesRemoved, equals(10));
      expect(result.entriesRetained, equals(5));
      expect(result.bytesFreed, equals(500));
    });

    test('contains baseVersion', () {
      final result = CompactionResult(
        entriesRemoved: 10,
        entriesRetained: 5,
        bytesFreed: 500,
        baseVersion: version,
      );

      expect(result.baseVersion, equals(version));
    });

    test('equality works correctly', () {
      final result1 = CompactionResult(
        entriesRemoved: 10,
        entriesRetained: 5,
        bytesFreed: 500,
        baseVersion: version,
      );
      final result2 = CompactionResult(
        entriesRemoved: 10,
        entriesRetained: 5,
        bytesFreed: 500,
        baseVersion: version,
      );

      expect(result1, equals(result2));
    });

    test('hashCode is consistent with equality', () {
      final result1 = CompactionResult(
        entriesRemoved: 10,
        entriesRetained: 5,
        bytesFreed: 500,
        baseVersion: version,
      );
      final result2 = CompactionResult(
        entriesRemoved: 10,
        entriesRetained: 5,
        bytesFreed: 500,
        baseVersion: version,
      );

      expect(result1.hashCode, equals(result2.hashCode));
    });
  });
}
