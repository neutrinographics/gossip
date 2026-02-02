import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/log_entry_id.dart';

void main() {
  group('LogEntry', () {
    final author1 = NodeId('node-1');
    final author2 = NodeId('node-2');
    final timestamp = Hlc(1000, 5);
    final payload = Uint8List.fromList([1, 2, 3, 4]);

    test(
      'two entries with same author and sequence are equal (payload ignored)',
      () {
        final entry1 = LogEntry(
          author: author1,
          sequence: 5,
          timestamp: timestamp,
          payload: payload,
        );
        final entry2 = LogEntry(
          author: author1,
          sequence: 5,
          timestamp: Hlc(2000, 10), // Different timestamp
          payload: Uint8List.fromList([5, 6, 7]), // Different payload
        );

        expect(entry1, equals(entry2));
      },
    );

    test('entries with different authors are not equal', () {
      final entry1 = LogEntry(
        author: author1,
        sequence: 5,
        timestamp: timestamp,
        payload: payload,
      );
      final entry2 = LogEntry(
        author: author2,
        sequence: 5,
        timestamp: timestamp,
        payload: payload,
      );

      expect(entry1, isNot(equals(entry2)));
    });

    test('entries with different sequences are not equal', () {
      final entry1 = LogEntry(
        author: author1,
        sequence: 5,
        timestamp: timestamp,
        payload: payload,
      );
      final entry2 = LogEntry(
        author: author1,
        sequence: 6,
        timestamp: timestamp,
        payload: payload,
      );

      expect(entry1, isNot(equals(entry2)));
    });

    test('id returns correct LogEntryId', () {
      final entry = LogEntry(
        author: author1,
        sequence: 5,
        timestamp: timestamp,
        payload: payload,
      );

      expect(entry.id, equals(LogEntryId(author1, 5)));
    });

    test('sizeBytes returns correct estimation', () {
      final entry = LogEntry(
        author: author1,
        sequence: 5,
        timestamp: timestamp,
        payload: Uint8List.fromList([1, 2, 3, 4]), // 4 bytes
      );

      // 52 (overhead) + 4 (payload) = 56
      expect(entry.sizeBytes, equals(56));
    });

    test('hashCode is consistent with equality', () {
      final entry1 = LogEntry(
        author: author1,
        sequence: 5,
        timestamp: timestamp,
        payload: payload,
      );
      final entry2 = LogEntry(
        author: author1,
        sequence: 5,
        timestamp: Hlc(2000, 10),
        payload: Uint8List.fromList([5, 6, 7]),
      );
      final entry3 = LogEntry(
        author: author1,
        sequence: 6,
        timestamp: timestamp,
        payload: payload,
      );

      expect(entry1.hashCode, equals(entry2.hashCode));
      expect(entry1.hashCode, isNot(equals(entry3.hashCode)));
    });

    test('toString returns readable representation', () {
      final entry = LogEntry(
        author: NodeId('node-1'),
        sequence: 42,
        timestamp: Hlc(5000, 10),
        payload: payload,
      );

      expect(entry.toString(), equals('LogEntry(node-1:42 @Hlc(5000:10))'));
    });

    group('invariant validation', () {
      test('constructor throws ArgumentError when sequence is zero', () {
        expect(
          () => LogEntry(
            author: author1,
            sequence: 0,
            timestamp: timestamp,
            payload: payload,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('constructor throws ArgumentError when sequence is negative', () {
        expect(
          () => LogEntry(
            author: author1,
            sequence: -1,
            timestamp: timestamp,
            payload: payload,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('constructor accepts sequence of 1', () {
        final entry = LogEntry(
          author: author1,
          sequence: 1,
          timestamp: timestamp,
          payload: payload,
        );
        expect(entry.sequence, equals(1));
      });

      test('constructor accepts large positive sequence', () {
        final entry = LogEntry(
          author: author1,
          sequence: 999999,
          timestamp: timestamp,
          payload: payload,
        );
        expect(entry.sequence, equals(999999));
      });
    });
  });
}
