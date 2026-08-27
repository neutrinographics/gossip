import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/sync/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';

void main() {
  group('RetentionPolicy', () {
    final author1 = NodeId('node-1');
    final author2 = NodeId('node-2');
    final author3 = NodeId('node-3');

    LogEntry makeEntry(NodeId author, int seq, int timestampMs) => LogEntry(
      author: author,
      sequence: seq,
      timestamp: Hlc(timestampMs, 0),
      payload: Uint8List.fromList([1, 2, 3]),
    );

    group('retainsAll', () {
      test(
        'KeepAllRetention.retainsAll is true (auto-compaction skips it)',
        () {
          expect(const KeepAllRetention().retainsAll, isTrue);
        },
      );

      test('pruning policies report retainsAll false', () {
        expect(
          TimeBasedRetention(const Duration(seconds: 5)).retainsAll,
          isFalse,
        );
        expect(const CountBasedRetention(1).retainsAll, isFalse);
        expect(
          CompositeRetention(const [CountBasedRetention(1)]).retainsAll,
          isFalse,
        );
      });

      test('a composite containing a retain-all policy retains all (union)', () {
        // Union semantics: if any sub-policy keeps everything, nothing prunes.
        expect(
          CompositeRetention(const [
            KeepAllRetention(),
            CountBasedRetention(1),
          ]).retainsAll,
          isTrue,
        );
      });
    });

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
      test('retains everything when the clock is younger than maxAge', () {
        // now=1s, maxAge=1h: the cutoff would be negative. Hlc.subtract
        // throws on negative results — compaction must retain all entries
        // instead of blowing up (common with test clocks starting at 0).
        final policy = TimeBasedRetention(const Duration(hours: 1));
        final entries = [
          makeEntry(author1, 1, 500),
          makeEntry(author1, 2, 800),
        ];
        final now = Hlc(1000, 0);

        final result = policy.compact(entries, now);

        expect(result, equals(entries));
      });

      test('filters entries older than maxAge', () {
        final policy = TimeBasedRetention(const Duration(seconds: 5));
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
        final policy = TimeBasedRetention(const Duration(seconds: 5));
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

    group('constructor guards', () {
      test('TimeBasedRetention rejects a negative maxAge', () {
        expect(
          () => TimeBasedRetention(const Duration(seconds: -1)),
          throwsA(isA<AssertionError>()),
        );
      });

      test('CountBasedRetention accepts zero (deliberately prunes everything '
          '— see compaction_late_joiner_test\'s floor-only scenario)', () {
        expect(const CountBasedRetention(0).maxEntriesPerAuthor, equals(0));
      });

      test('CountBasedRetention rejects a negative maxEntriesPerAuthor', () {
        expect(() => CountBasedRetention(-1), throwsA(isA<AssertionError>()));
      });

      test('CompositeRetention rejects an empty policy list', () {
        expect(
          () => CompositeRetention(const []),
          throwsA(isA<AssertionError>()),
        );
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
          // author3's only entry: old enough that TimeBasedRetention drops
          // it (timestamp 500 is well before the 7000 cutoff), but it's
          // author3's most recent (only) entry, so CountBasedRetention
          // keeps it. Retained by exactly one sub-policy: this is the entry
          // that distinguishes union semantics from intersection semantics.
          // Without it, every entry above is either kept-by-both or
          // dropped-by-both, so a composite that intersects instead of
          // unions would pass this test just as well.
          makeEntry(author3, 1, 500),
        ];
        final now = Hlc(10000, 0);

        final result = policy.compact(entries, now);

        // 3 should be kept:
        // - entry1 dropped by both (too old, not highest seq)
        // - entry2 kept by both
        // - entry3 kept by both
        // - entry4 kept by count only, dropped by time — union retains it
        expect(result.length, equals(3));
        expect(result[0].sequence, equals(2));
        expect(result[0].author, equals(author1));
        expect(result[1].sequence, equals(1));
        expect(result[1].author, equals(author2));
        expect(result[2].sequence, equals(1));
        expect(result[2].author, equals(author3));
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
