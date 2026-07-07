import 'dart:typed_data';

import 'package:gossip/src/domain/interfaces/retention_policy.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/facade/coordinator.dart';
import 'package:gossip/src/facade/coordinator_config.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_channel_repository.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_local_node_repository.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_peer_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:test/test.dart';

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

    test('auto-compaction is disabled when compactionInterval is null',
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
    });
  });
}
