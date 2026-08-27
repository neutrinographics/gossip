import 'dart:typed_data';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/sync/application/reactive_pusher.dart';
import 'package:test/test.dart';

import '../../support/scripted_delay_time_port.dart';

/// Transplanted from gossip_engine_scheduling_test.dart / the
/// gossip_engine.dart `notifyLocalWrite`/`_flushPendingPushes` debounce
/// machinery, now pinned directly against
/// [ReactivePusher] instead of only through `GossipEngine`. The engine's
/// own reactive-push tests (gossip_engine_reactive_push_test.dart,
/// gossip_engine_scheduling_test.dart) stay in place unmodified — they
/// pin the same behavior end-to-end through the engine's public API.
void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');
  final localNode = NodeId('local');

  LogEntry entry(int seq) => LogEntry(
    author: localNode,
    sequence: seq,
    timestamp: Hlc(1000 + seq, 0),
    payload: Uint8List.fromList([seq]),
  );

  group('ReactivePusher', () {
    test('a burst of writes within the debounce window coalesces into one '
        'flush containing all entries', () async {
      final timePort = InMemoryTimePort();
      final flushes = <Map<(ChannelId, StreamId), List<LogEntry>>>[];
      final pusher = ReactivePusher(
        timePort: timePort,
        isRunning: () => true,
        flush: (batches) async => flushes.add(batches),
        onSchedulingFailure: (error, stackTrace) => fail('unexpected: $error'),
      );

      pusher.notifyWrite(channelId, streamId, entry(1));
      pusher.notifyWrite(channelId, streamId, entry(2));
      pusher.notifyWrite(channelId, streamId, entry(3));

      // Nothing flushes before the debounce window elapses.
      await pumpEventQueue();
      expect(flushes, isEmpty);

      await timePort.advance(const Duration(milliseconds: 150));
      await pumpEventQueue();

      expect(
        flushes,
        hasLength(1),
        reason: 'the whole burst must coalesce into a single flush',
      );
      expect(
        flushes.single[(channelId, streamId)]!.map((e) => e.sequence),
        equals([1, 2, 3]),
      );
    });

    test('notifyWrite is a no-op when not running', () async {
      final timePort = InMemoryTimePort();
      var flushCount = 0;
      final pusher = ReactivePusher(
        timePort: timePort,
        isRunning: () => false,
        flush: (batches) async => flushCount++,
        onSchedulingFailure: (error, stackTrace) => fail('unexpected: $error'),
      );

      pusher.notifyWrite(channelId, streamId, entry(1));
      await timePort.advance(const Duration(milliseconds: 150));
      await pumpEventQueue();

      expect(flushCount, equals(0));
      expect(
        timePort.pendingDelayCount,
        equals(0),
        reason: 'not running must not even schedule a debounce',
      );
    });

    test('a debounce scheduled before invalidate() recognizes itself as '
        'stale and does nothing', () async {
      final timePort = InMemoryTimePort();
      var flushCount = 0;
      final pusher = ReactivePusher(
        timePort: timePort,
        isRunning: () => true,
        flush: (batches) async => flushCount++,
        onSchedulingFailure: (error, stackTrace) => fail('unexpected: $error'),
      );

      pusher.notifyWrite(channelId, streamId, entry(1));
      pusher.invalidate();

      await timePort.advance(const Duration(milliseconds: 150));
      await pumpEventQueue();

      expect(
        flushCount,
        equals(0),
        reason: 'invalidate() must make the in-flight debounce stale',
      );
    });

    test('invalidateAndClear drops the buffer', () async {
      final timePort = InMemoryTimePort();
      final flushes = <Map<(ChannelId, StreamId), List<LogEntry>>>[];
      final pusher = ReactivePusher(
        timePort: timePort,
        isRunning: () => true,
        flush: (batches) async => flushes.add(batches),
        onSchedulingFailure: (error, stackTrace) => fail('unexpected: $error'),
      );

      pusher.notifyWrite(channelId, streamId, entry(1));
      pusher.invalidateAndClear();

      // A fresh write after invalidateAndClear must schedule its own
      // debounce (the flag was reset) and must not carry entry 1 forward
      // (the buffer was cleared, not just made stale).
      pusher.notifyWrite(channelId, streamId, entry(2));
      await timePort.advance(const Duration(milliseconds: 150));
      await pumpEventQueue();

      expect(flushes, hasLength(1));
      expect(
        flushes.single[(channelId, streamId)]!.map((e) => e.sequence),
        equals([2]),
        reason: 'entry 1 must have been dropped, not merely superseded',
      );
    });

    test('a debounce-delay failure clears the flag and buffer, reports via '
        'onSchedulingFailure, and a subsequent write reschedules', () async {
      // ScriptedDelayTimePort addresses delay() calls by 1-indexed
      // position: call #1 below is notifyWrite's debounce for entry 1,
      // scripted to fail; call #2 is the subsequent write's debounce,
      // which must go through normally.
      final timePort = ScriptedDelayTimePort(failDelayCalls: {1});
      final flushes = <Map<(ChannelId, StreamId), List<LogEntry>>>[];
      final failures = <Object>[];
      final pusher = ReactivePusher(
        timePort: timePort,
        isRunning: () => true,
        flush: (batches) async => flushes.add(batches),
        onSchedulingFailure: (error, stackTrace) => failures.add(error),
      );

      pusher.notifyWrite(channelId, streamId, entry(1)); // call #1
      await pumpEventQueue();

      expect(
        failures,
        hasLength(1),
        reason: 'the delay failure must be reported via onSchedulingFailure',
      );

      pusher.notifyWrite(channelId, streamId, entry(2)); // call #2
      await timePort.advance(const Duration(milliseconds: 150));
      await pumpEventQueue();

      expect(flushes, hasLength(1));
      expect(
        flushes.single[(channelId, streamId)]!.map((e) => e.sequence),
        equals([2]),
        reason:
            'entry 1 must have been dropped by the failure-path buffer '
            'clear, and the subsequent write must not be wedged by a '
            'stuck flag',
      );
    });

    test(
      'after onRoundLoopDead an in-flight debounce is stale, and a later '
      'write (once running again) schedules a fresh flush — the wedge pin',
      () async {
        final timePort = InMemoryTimePort();
        final flushes = <Map<(ChannelId, StreamId), List<LogEntry>>>[];
        var running = true;
        final pusher = ReactivePusher(
          timePort: timePort,
          isRunning: () => running,
          flush: (batches) async => flushes.add(batches),
          onSchedulingFailure: (error, stackTrace) =>
              fail('unexpected: $error'),
        );

        pusher.notifyWrite(channelId, streamId, entry(1)); // schedules #1
        running = false; // as if the round loop just died
        pusher.onRoundLoopDead();

        // The in-flight debounce is now stale — it must not flush even
        // once its 150ms elapses.
        await timePort.advance(const Duration(milliseconds: 150));
        await pumpEventQueue();
        expect(flushes, isEmpty);

        // Once running again, a fresh write must schedule its own
        // debounce. With the wedge (bump but no flag reset), this
        // write would find `_pushFlushScheduled` still true and silently
        // do nothing.
        running = true;
        pusher.notifyWrite(channelId, streamId, entry(2));
        await timePort.advance(const Duration(milliseconds: 150));
        await pumpEventQueue();

        expect(
          flushes,
          hasLength(1),
          reason:
              'a write after the round loop recovers must not be '
              'permanently wedged',
        );
        expect(
          flushes.single[(channelId, streamId)]!.map((e) => e.sequence),
          equals([1, 2]),
          reason:
              'onRoundLoopDead does not clear the buffer (only '
              'invalidateAndClear does), so entry 1 rides along with the '
              'next successful flush',
        );
      },
    );
  });
}
