import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/domain/results/merge_result.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';

void main() {
  group('MergeResult', () {
    final author = NodeId('node-1');
    final entry1 = LogEntry(
      author: author,
      sequence: 1,
      timestamp: Hlc(1000, 0),
      payload: Uint8List.fromList([1]),
    );
    final entry2 = LogEntry(
      author: author,
      sequence: 2,
      timestamp: Hlc(2000, 0),
      payload: Uint8List.fromList([2]),
    );

    test('MergeResult.empty() has empty lists and empty version', () {
      final result = MergeResult.empty();

      expect(result.newEntries, isEmpty);
      expect(result.duplicates, isEmpty);
      expect(result.outOfOrder, isEmpty);
      expect(result.dropped, isEmpty);
      expect(result.rejected, isEmpty);
      expect(result.newVersion, equals(VersionVector.empty));
    });

    test('hasNewEntries returns true when newEntries is non-empty', () {
      final result = MergeResult(
        newEntries: [entry1],
        duplicates: [],
        outOfOrder: [],
        dropped: [],
        rejected: [],
        newVersion: VersionVector.empty,
      );

      expect(result.hasNewEntries, isTrue);
    });

    test('hasNewEntries returns false when newEntries is empty', () {
      final result = MergeResult.empty();

      expect(result.hasNewEntries, isFalse);
    });

    test('hasOutOfOrder returns true when outOfOrder is non-empty', () {
      final result = MergeResult(
        newEntries: [],
        duplicates: [],
        outOfOrder: [entry1],
        dropped: [],
        rejected: [],
        newVersion: VersionVector.empty,
      );

      expect(result.hasOutOfOrder, isTrue);
    });

    test('hasDropped returns true when dropped is non-empty', () {
      final result = MergeResult(
        newEntries: [],
        duplicates: [],
        outOfOrder: [],
        dropped: [entry1],
        rejected: [],
        newVersion: VersionVector.empty,
      );

      expect(result.hasDropped, isTrue);
    });

    test('hasRejected returns true when rejected is non-empty', () {
      final result = MergeResult(
        newEntries: [],
        duplicates: [],
        outOfOrder: [],
        dropped: [],
        rejected: [entry1],
        newVersion: VersionVector.empty,
      );

      expect(result.hasRejected, isTrue);
    });

    test('totalProcessed sums all lists', () {
      final result = MergeResult(
        newEntries: [entry1],
        duplicates: [entry2],
        outOfOrder: [entry1],
        dropped: [entry2],
        rejected: [entry1],
        newVersion: VersionVector.empty,
      );

      expect(result.totalProcessed, equals(5));
    });
  });
}
