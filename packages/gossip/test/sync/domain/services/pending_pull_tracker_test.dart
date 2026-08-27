import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/sync/domain/services/pending_pull_tracker.dart';
import 'package:test/test.dart';

/// Transplanted from gossip_engine_delta_budget_test.dart (M3 pending-delta
/// dedup group) and gossip_engine_pending_delta_test.dart/
/// gossip_engine_sync_activity_test.dart (adaptive timeout, outstanding
/// count), now pinned directly against [PendingPullTracker] (CC5-1, task
/// F4) instead of only through `GossipEngine`.
void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');
  final peerA = NodeId('peerA');
  final peerB = NodeId('peerB');

  late InMemoryTimePort timePort;
  late PendingPullTracker tracker;

  setUp(() {
    timePort = InMemoryTimePort();
    tracker = PendingPullTracker(timePort: timePort);
  });

  group('tryMark dedup gate', () {
    test('refuses a second mark for the same key while the first is live', () {
      expect(tracker.tryMark(peerA, channelId, streamId), isTrue);
      expect(
        tracker.tryMark(peerA, channelId, streamId),
        isFalse,
        reason: 'a live (non-expired) entry must block a duplicate mark',
      );
    });

    test('accepts a different key even while another is live', () {
      expect(tracker.tryMark(peerA, channelId, streamId), isTrue);
      expect(
        tracker.tryMark(peerB, channelId, streamId),
        isTrue,
        reason: 'per-peer keying: a different peer is a different key',
      );
    });

    test('accepts a re-mark once the prior entry ages past effectiveTimeout '
        '(expired entries are replaced)', () async {
      expect(tracker.tryMark(peerA, channelId, streamId), isTrue);

      // Cold-start default is 8s; advance just past it.
      await timePort.advance(const Duration(seconds: 8, milliseconds: 1));

      expect(
        tracker.tryMark(peerA, channelId, streamId),
        isTrue,
        reason: 'an expired entry must be replaced, not treated as live',
      );
    });

    test('still refuses just before the entry expires', () async {
      expect(tracker.tryMark(peerA, channelId, streamId), isTrue);

      await timePort.advance(const Duration(seconds: 7, milliseconds: 999));

      expect(tracker.tryMark(peerA, channelId, streamId), isFalse);
    });
  });

  group('release', () {
    test('frees a live entry for immediate re-marking', () {
      expect(tracker.tryMark(peerA, channelId, streamId), isTrue);

      tracker.release(peerA, channelId, streamId);

      expect(
        tracker.tryMark(peerA, channelId, streamId),
        isTrue,
        reason: 'release must clear the entry, not merely mark it expired',
      );
    });

    test('releasing an untracked key is a no-op', () {
      expect(
        () => tracker.release(peerA, channelId, streamId),
        returnsNormally,
      );
    });
  });

  group('markContinuation', () {
    test('marks the key as freshly pending, blocking a concurrent tryMark', () {
      tracker.markContinuation(peerA, channelId, streamId);

      expect(
        tracker.tryMark(peerA, channelId, streamId),
        isFalse,
        reason: 'a continuation request is itself a live pending pull',
      );
    });
  });

  group('complete', () {
    test('returns null and removes nothing for an untracked key', () {
      expect(tracker.complete(peerA, channelId, streamId), isNull);
    });

    test('removes the entry and returns the elapsed milliseconds', () async {
      tracker.tryMark(peerA, channelId, streamId);

      await timePort.advance(const Duration(milliseconds: 500));

      expect(tracker.complete(peerA, channelId, streamId), equals(500));
      // The key is gone, so an immediate re-mark succeeds (would be
      // refused at 500ms elapsed if the entry were still live).
      expect(tracker.tryMark(peerA, channelId, streamId), isTrue);
    });

    test('does not feed a zero-elapsed reading into the RTT estimator '
        '(elapsedMs > 0 guard)', () {
      tracker.tryMark(peerA, channelId, streamId);

      // No time advance: elapsed is exactly 0ms.
      expect(tracker.complete(peerA, channelId, streamId), equals(0));

      // No sample was recorded, so effectiveTimeout is still the cold
      // default rather than shifted by a spurious 0ms sample.
      expect(tracker.effectiveTimeout, equals(const Duration(seconds: 8)));
    });

    test('feeds a positive elapsed reading into the EWMA, observable via '
        'effectiveTimeout shifting away from the cold default', () async {
      tracker.tryMark(peerA, channelId, streamId);

      await timePort.advance(const Duration(seconds: 6));
      tracker.complete(peerA, channelId, streamId);

      expect(
        tracker.effectiveTimeout.inMilliseconds,
        greaterThan(const Duration(seconds: 6).inMilliseconds),
        reason:
            'the timeout must exceed the observed 6s round-trip so a page '
            'in flight is never re-requested mid-transmission',
      );
      expect(
        tracker.effectiveTimeout,
        isNot(equals(const Duration(seconds: 8))),
        reason: 'a real sample must move the estimate off the cold default',
      );
    });
  });

  group('effectiveTimeout cold start and clamping', () {
    test('defaults to 8s before any sample is recorded', () {
      expect(tracker.effectiveTimeout, equals(const Duration(seconds: 8)));
    });

    test('clamps a very fast round-trip sample up to the 2s floor before it '
        'reaches the RTT estimator (not just the final output)', () async {
      tracker.tryMark(peerA, channelId, streamId);

      // 1ms round trip: if the elapsed reading were fed to the estimator
      // unclamped, the first-sample rule would set smoothedRtt=1ms,
      // variance=0.5ms, giving suggestedTimeout=3ms — clamped only at the
      // very end to the 2s floor. Clamping the SAMPLE itself to 2s first
      // (via clampDuration) instead yields smoothedRtt=2s, variance=1s,
      // suggestedTimeout=2s+4*1s=6s: a different, larger result that only
      // happens if the pre-estimator clamp actually ran.
      await timePort.advance(const Duration(milliseconds: 1));
      tracker.complete(peerA, channelId, streamId);

      expect(tracker.effectiveTimeout, equals(const Duration(seconds: 6)));
    });

    test(
      'clamps an extreme round-trip sample down to the 30s ceiling',
      () async {
        tracker.tryMark(peerA, channelId, streamId);

        await timePort.advance(const Duration(seconds: 100));
        tracker.complete(peerA, channelId, streamId);

        expect(tracker.effectiveTimeout, equals(const Duration(seconds: 30)));
      },
    );
  });

  group('outstandingCount', () {
    test('counts live pending entries', () {
      expect(tracker.outstandingCount, equals(0));

      tracker.tryMark(peerA, channelId, streamId);
      expect(tracker.outstandingCount, equals(1));

      tracker.tryMark(peerB, channelId, streamId);
      expect(tracker.outstandingCount, equals(2));
    });

    test('excludes expired entries', () async {
      tracker.tryMark(peerA, channelId, streamId);
      expect(tracker.outstandingCount, equals(1));

      await timePort.advance(const Duration(seconds: 8, milliseconds: 1));

      expect(
        tracker.outstandingCount,
        equals(0),
        reason: 'a pull whose peer never answered is dead, not still syncing',
      );
    });

    test('drops to zero once the entry is completed', () async {
      tracker.tryMark(peerA, channelId, streamId);
      tracker.complete(peerA, channelId, streamId);

      expect(tracker.outstandingCount, equals(0));
    });
  });

  group('clearAll', () {
    test('removes every pending entry, freeing all keys immediately', () {
      tracker.tryMark(peerA, channelId, streamId);
      tracker.tryMark(peerB, channelId, streamId);

      tracker.clearAll();

      expect(tracker.outstandingCount, equals(0));
      expect(tracker.tryMark(peerA, channelId, streamId), isTrue);
      expect(tracker.tryMark(peerB, channelId, streamId), isTrue);
    });
  });

  group('clearForPeer', () {
    test('removes only the given peer\'s keys', () {
      final otherStream = StreamId('s2');
      tracker.tryMark(peerA, channelId, streamId);
      tracker.tryMark(peerA, channelId, otherStream);
      tracker.tryMark(peerB, channelId, streamId);

      tracker.clearForPeer(peerA);

      expect(
        tracker.outstandingCount,
        equals(1),
        reason: 'only peerB\'s entry should survive',
      );
      // peerA's keys are immediately re-markable (proves removal, not
      // merely exclusion from the count).
      expect(tracker.tryMark(peerA, channelId, streamId), isTrue);
      expect(tracker.tryMark(peerA, channelId, otherStream), isTrue);
      // peerB's entry is untouched and still live.
      expect(tracker.tryMark(peerB, channelId, streamId), isFalse);
    });
  });
}
