import 'dart:typed_data';

import 'package:gossip/src/sync/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/coordinator/coordinator_config.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:test/test.dart';

import '../support/coordinator_builder.dart';
import '../support/failing_delay_time_port.dart';

void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');

  group('Coordinator auto-compaction (G3)', () {
    test(
      'streams are compacted per their retention policy on the interval',
      () async {
        final timePort = InMemoryTimePort();
        final coordinator = await createTestCoordinator(
          bus: InMemoryMessageBus(),
          timePort: timePort,
          config: const CoordinatorConfig(
            gossipInterval: Duration(seconds: 100),
            probeInterval: Duration(seconds: 100),
            pingTimeout: Duration(seconds: 100),
            startupGracePeriod: Duration.zero,
            compactionInterval: Duration(minutes: 1),
          ),
        );
        await coordinator.start();
        final channel = await coordinator.createChannel(channelId);
        final stream = await channel.getOrCreateStream(
          streamId,
          retention: const CountBasedRetention(1),
        );

        for (var i = 0; i < 5; i++) {
          await stream.append(Uint8List.fromList([i]));
        }
        expect((await stream.getAll()).length, equals(5));

        // Advance past the compaction interval.
        await timePort.advance(const Duration(minutes: 1));
        await pumpEventQueue();

        expect(
          (await stream.getAll()).length,
          equals(1),
          reason:
              'CountBasedRetention(1) keeps only the latest — the library '
              'must enforce it, not just declare it',
        );
      },
    );

    test(
      'auto-compaction is disabled when compactionInterval is null',
      () async {
        final timePort = InMemoryTimePort();
        final coordinator = await createTestCoordinator(
          bus: InMemoryMessageBus(),
          timePort: timePort,
          config: const CoordinatorConfig(
            gossipInterval: Duration(seconds: 100),
            probeInterval: Duration(seconds: 100),
            pingTimeout: Duration(seconds: 100),
            startupGracePeriod: Duration.zero,
            compactionInterval: null,
          ),
        );
        await coordinator.start();
        final channel = await coordinator.createChannel(channelId);
        final stream = await channel.getOrCreateStream(
          streamId,
          retention: const CountBasedRetention(1),
        );
        for (var i = 0; i < 5; i++) {
          await stream.append(Uint8List.fromList([i]));
        }

        await timePort.advance(const Duration(hours: 1));
        await pumpEventQueue();

        expect(
          (await stream.getAll()).length,
          equals(5),
          reason: 'null interval opts out of auto-compaction',
        );
      },
    );
  });

  group('Coordinator auto-compaction scheduling failure', () {
    test('a delay failure emits exactly one scheduling error and the loop '
        'stays dead until the next stop/start cycle', () async {
      final timePort = FailingDelayTimePort();
      final errors = <SyncError>[];
      // Timer port only, no message port: isolates the compaction
      // scheduler's delay() calls from the gossip/failure-detector loops,
      // which would otherwise race it for the first (failing) delay.
      final coordinator = await createTestCoordinator(
        timePort: timePort,
        config: const CoordinatorConfig(
          compactionInterval: Duration(milliseconds: 50),
        ),
        onError: errors.add,
      );

      timePort.failNextDelay = true;
      await coordinator.start();

      // Let the failed delay future propagate.
      await pumpEventQueue();

      expect(errors, hasLength(1));
      expect(
        errors.single,
        isA<StorageSyncError>().having(
          (e) => e.message,
          'message',
          contains('Auto-compaction scheduling failed'),
        ),
        reason: 'a scheduling failure must surface via ErrorCallback',
      );

      // The errors-stream assertions alone can't distinguish "loop is
      // dead" from "loop is retrying but ticking a no-op" (compactAll()
      // with no channels registered is silently a no-op either way).
      // Assert isRunning directly: a retrying scheduler would still
      // report itself running.
      expect(
        coordinator.compactionSchedulerForTesting!.isRunning,
        isFalse,
        reason:
            'a scheduler that retries after a scheduling failure would '
            'still report isRunning == true here — a scheduling failure '
            'must stop the loop, not retry it',
      );

      // Advancing time well past several intervals ticks nothing further —
      // the scheduler stopped itself rather than silently dying.
      await timePort.inner.advance(const Duration(seconds: 1));
      await pumpEventQueue();
      expect(
        errors,
        hasLength(1),
        reason: 'no further compaction ticks until a stop/start cycle',
      );

      // A fresh stop/start cycle resumes the loop cleanly (no leftover
      // failure — failNextDelay only fired once).
      await coordinator.stop();
      await coordinator.start();

      // "No further errors" alone can't tell a restarted loop from a
      // loop that never came back — assert isRunning directly, the same
      // way the pre-restart leg does for the dead state.
      expect(
        coordinator.compactionSchedulerForTesting!.isRunning,
        isTrue,
        reason:
            'the stop/start cycle must leave a live scheduler behind, not '
            'a dead one masked by "no channels to compact" being a no-op '
            'either way',
      );

      await timePort.inner.advance(const Duration(seconds: 1));
      await pumpEventQueue();
      expect(
        errors,
        hasLength(1),
        reason: 'resumed loop ticks cleanly with no channels to compact',
      );
    });
  });
}
