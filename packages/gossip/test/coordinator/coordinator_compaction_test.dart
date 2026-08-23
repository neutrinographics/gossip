import 'dart:typed_data';

import 'package:gossip/src/sync/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/coordinator/coordinator.dart';
import 'package:gossip/src/coordinator/coordinator_config.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/membership/infrastructure/in_memory_peer_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:test/test.dart';

import '../support/failing_delay_time_port.dart';

void main() {
  final localNode = NodeId('local');
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');

  group('Coordinator auto-compaction (G3)', () {
    test(
      'streams are compacted per their retention policy on the interval',
      () async {
        final timePort = InMemoryTimePort();
        final coordinator = await Coordinator.create(
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
          channelRepository: InMemoryChannelRepository(),
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
          messagePort: InMemoryMessagePort(localNode, InMemoryMessageBus()),
          timerPort: timePort,
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
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(
          (await stream.getAll()).length,
          equals(1),
          reason:
              'CountBasedRetention(1) keeps only the latest — the library '
              'must enforce it, not just declare it',
        );

        await coordinator.dispose();
      },
    );

    test(
      'auto-compaction is disabled when compactionInterval is null',
      () async {
        final timePort = InMemoryTimePort();
        final coordinator = await Coordinator.create(
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
          channelRepository: InMemoryChannelRepository(),
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
          messagePort: InMemoryMessagePort(localNode, InMemoryMessageBus()),
          timerPort: timePort,
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
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(
          (await stream.getAll()).length,
          equals(5),
          reason: 'null interval opts out of auto-compaction',
        );

        await coordinator.dispose();
      },
    );
  });

  group('Coordinator auto-compaction scheduling failure (BD2)', () {
    test('a delay failure emits exactly one scheduling error and the loop '
        'stays dead until the next stop/start cycle', () async {
      final timePort = FailingDelayTimePort();
      final errors = <SyncError>[];
      // Timer port only, no message port: isolates the compaction
      // scheduler's delay() calls from the gossip/failure-detector loops,
      // which would otherwise race it for the first (failing) delay.
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        timerPort: timePort,
        config: const CoordinatorConfig(
          compactionInterval: Duration(milliseconds: 50),
        ),
      );
      coordinator.errors.listen(errors.add);

      timePort.failNextDelay = true;
      await coordinator.start();

      // Let the failed delay future propagate.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(errors, hasLength(1));
      expect(
        errors.single,
        isA<StorageSyncError>().having(
          (e) => e.message,
          'message',
          contains('Auto-compaction scheduling failed'),
        ),
        reason: 'BD2: a scheduling failure must surface via ErrorCallback',
      );

      // Advancing time well past several intervals ticks nothing further —
      // the scheduler stopped itself rather than silently dying.
      await timePort.inner.advance(const Duration(seconds: 1));
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        errors,
        hasLength(1),
        reason: 'no further compaction ticks until a stop/start cycle',
      );

      // A fresh stop/start cycle resumes the loop cleanly (no leftover
      // failure — failNextDelay only fired once).
      await coordinator.stop();
      await coordinator.start();
      await timePort.inner.advance(const Duration(seconds: 1));
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        errors,
        hasLength(1),
        reason: 'resumed loop ticks cleanly with no channels to compact',
      );

      await coordinator.dispose();
    });
  });
}
