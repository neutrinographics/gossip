import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';

void main() {
  group('RetentionPolicy', () {
    final author1 = NodeId('node-1');
    final author2 = NodeId('node-2');

    LogEntry makeEntry(NodeId author, int seq, int timestampMs) => LogEntry(
      author: author,
      sequence: seq,
      timestamp: Hlc(timestampMs, 0),
      payload: Uint8List.fromList([1, 2, 3]),
    );

    group('KeepAllRetention', () {
      test('returns all entries unchanged', () {
        const policy = KeepAllRetention();
        final entries = [
          makeEntry(author1, 1, 1000),
          makeEntry(author1, 2, 2000),
        ];
        final now = Hlc(10000, 0);

        final result = policy.compact(entries, now);

        expect(result, equals(entries));
        expect(identical(result, entries), isTrue); // Same instance
      });
    });

    group('TimeBasedRetention', () {
      test('filters entries older than maxAge', () {
        const policy = TimeBasedRetention(Duration(seconds: 5));
        final entries = [
          makeEntry(author1, 1, 1000), // 9 seconds old
          makeEntry(author1, 2, 6000), // 4 seconds old
          makeEntry(author1, 3, 7000), // 3 seconds old
        ];
        final now = Hlc(10000, 0);

        final result = policy.compact(entries, now);

        expect(result.length, equals(2));
        expect(result[0].sequence, equals(2));
        expect(result[1].sequence, equals(3));
      });

      test('keeps entries at exactly the cutoff', () {
        const policy = TimeBasedRetention(Duration(seconds: 5));
        final entries = [
          makeEntry(author1, 1, 5000), // Exactly 5 seconds old
          makeEntry(author1, 2, 5001), // Just under 5 seconds
        ];
        final now = Hlc(10000, 0);

        final result = policy.compact(entries, now);

        expect(result.length, equals(2));
      });
    });

    group('CountBasedRetention', () {
      test('keeps N most recent per author', () {
        const policy = CountBasedRetention(2);
        final entries = [
          makeEntry(author1, 1, 1000),
          makeEntry(author1, 2, 2000),
          makeEntry(author1, 3, 3000),
          makeEntry(author1, 4, 4000),
        ];
        final now = Hlc(10000, 0);

        final result = policy.compact(entries, now);

        expect(result.length, equals(2));
        expect(result[0].sequence, equals(3));
        expect(result[1].sequence, equals(4));
      });

      test('preserves timestamp order in result', () {
        const policy = CountBasedRetention(2);
        final entries = [
          makeEntry(author1, 1, 1000),
          makeEntry(author2, 1, 1500),
          makeEntry(author1, 2, 2000),
          makeEntry(author2, 2, 2500),
          makeEntry(author1, 3, 3000),
        ];
        final now = Hlc(10000, 0);

        final result = policy.compact(entries, now);

        // Should keep: author1(2,3), author2(1,2) = 4 entries
        expect(result.length, equals(4));
        // Verify timestamp order preserved
        for (var i = 1; i < result.length; i++) {
          expect(
            result[i].timestamp >= result[i - 1].timestamp,
            isTrue,
            reason: 'Entries should be sorted by timestamp',
          );
        }
      });
    });

    group('CompositeRetention', () {
      test('keeps entries retained by ANY policy', () {
        final policy = CompositeRetention([
          TimeBasedRetention(Duration(seconds: 3)), // Keep last 3 seconds
          CountBasedRetention(1), // Keep last 1 per author
        ]);
        final entries = [
          makeEntry(author1, 1, 1000), // Too old, and NOT last (seq 2 is last)
          makeEntry(author1, 2, 8000), // Recent and last for author1
          makeEntry(author2, 1, 9000), // Recent and last for author2
        ];
        final now = Hlc(10000, 0);

        final result = policy.compact(entries, now);

        // 2 should be kept:
        // - entry1 dropped by both (too old, not highest seq)
        // - entry2 kept by both
        // - entry3 kept by both
        expect(result.length, equals(2));
        expect(result[0].sequence, equals(2));
        expect(result[1].sequence, equals(1));
        expect(result[1].author, equals(author2));
      });

      test('deduplicates entries', () {
        final policy = CompositeRetention([
          KeepAllRetention(),
          KeepAllRetention(),
        ]);
        final entries = [
          makeEntry(author1, 1, 1000),
          makeEntry(author1, 2, 2000),
        ];
        final now = Hlc(10000, 0);

        final result = policy.compact(entries, now);

        // Should not duplicate entries even though both policies keep all
        expect(result.length, equals(2));
      });
    });
  });
}
