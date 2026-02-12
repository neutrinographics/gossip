import 'dart:typed_data';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/facade/coordinator.dart';
import 'package:gossip/src/facade/sync_state.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_channel_repository.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_local_node_repository.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_peer_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:test/test.dart';

void main() {
  group('ResourceUsage', () {
    test('has correct initial values with no data', () async {
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final usage = await coordinator.getResourceUsage();

      expect(usage.peerCount, equals(0));
      expect(usage.channelCount, equals(0));
      expect(usage.totalEntries, equals(0));
      expect(usage.totalStorageBytes, equals(0));
    });

    test('counts peers correctly', () async {
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.addPeer(NodeId('peer1'));
      await coordinator.addPeer(NodeId('peer2'));

      final usage = await coordinator.getResourceUsage();

      expect(usage.peerCount, equals(2));
    });

    test('counts channels correctly', () async {
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.createChannel(ChannelId('channel1'));
      await coordinator.createChannel(ChannelId('channel2'));
      await coordinator.createChannel(ChannelId('channel3'));

      final usage = await coordinator.getResourceUsage();

      expect(usage.channelCount, equals(3));
    });

    test('counts entries across all channels and streams', () async {
      final entryRepo = InMemoryEntryRepository();
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: entryRepo,
      );

      final channel1 = await coordinator.createChannel(ChannelId('channel1'));
      final stream1 = await channel1.getOrCreateStream(StreamId('stream1'));
      await stream1.append(Uint8List.fromList([1, 2, 3]));
      await stream1.append(Uint8List.fromList([4, 5, 6]));

      final channel2 = await coordinator.createChannel(ChannelId('channel2'));
      final stream2 = await channel2.getOrCreateStream(StreamId('stream2'));
      await stream2.append(Uint8List.fromList([7, 8, 9]));

      final usage = await coordinator.getResourceUsage();

      expect(usage.totalEntries, equals(3));
    });

    test('calculates storage bytes across all channels and streams', () async {
      final entryRepo = InMemoryEntryRepository();
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: entryRepo,
      );

      final channel = await coordinator.createChannel(ChannelId('channel1'));
      final stream = await channel.getOrCreateStream(StreamId('stream1'));
      await stream.append(Uint8List.fromList([1, 2, 3])); // 3 bytes payload
      await stream.append(
        Uint8List.fromList([4, 5, 6, 7, 8]),
      ); // 5 bytes payload

      final usage = await coordinator.getResourceUsage();

      // Storage bytes should be greater than 0 (includes entry overhead)
      expect(usage.totalStorageBytes, greaterThan(0));
    });
  });

  group('HealthStatus', () {
    test('reports correct state when stopped', () async {
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final health = await coordinator.getHealth();

      expect(health.state, equals(SyncState.stopped));
      expect(health.localNode, equals(NodeId('local')));
    });

    test('reports correct state when running', () async {
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.start();

      final health = await coordinator.getHealth();

      expect(health.state, equals(SyncState.running));
    });

    test('reports correct incarnation', () async {
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final health = await coordinator.getHealth();

      expect(health.incarnation, equals(0));
    });

    test('includes resource usage', () async {
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.addPeer(NodeId('peer1'));
      await coordinator.createChannel(ChannelId('channel1'));

      final health = await coordinator.getHealth();

      expect(health.resourceUsage.peerCount, equals(1));
      expect(health.resourceUsage.channelCount, equals(1));
    });

    test('reports reachable peer count', () async {
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.addPeer(NodeId('peer1'));
      await coordinator.addPeer(NodeId('peer2'));

      final health = await coordinator.getHealth();

      expect(health.reachablePeerCount, equals(2));
    });

    test('isHealthy returns true when running with reachable peers', () async {
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.addPeer(NodeId('peer1'));
      await coordinator.start();

      final health = await coordinator.getHealth();

      expect(health.isHealthy, isTrue);
    });

    test('isHealthy returns false when stopped', () async {
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.addPeer(NodeId('peer1'));

      final health = await coordinator.getHealth();

      expect(health.isHealthy, isFalse);
    });

    test(
      'isHealthy returns true when running with no peers (standalone mode)',
      () async {
        final coordinator = await Coordinator.create(
          localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
          channelRepository: InMemoryChannelRepository(),
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
        );

        await coordinator.start();

        final health = await coordinator.getHealth();

        // Standalone mode (no peers) is still healthy if running
        expect(health.isHealthy, isTrue);
      },
    );
  });

  group('AdaptiveTimingStatus', () {
    test('returns null in local-only mode (no ports)', () async {
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final timing = coordinator.getAdaptiveTimingStatus();

      expect(timing, isNull);
    });

    test('returns non-null when network sync is configured', () async {
      final bus = InMemoryMessageBus();
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: InMemoryMessagePort(NodeId('local'), bus),
        timerPort: InMemoryTimePort(),
      );

      final timing = coordinator.getAdaptiveTimingStatus();

      expect(timing, isNotNull);
    });

    test('reports initial conservative defaults before RTT samples', () async {
      final bus = InMemoryMessageBus();
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: InMemoryMessagePort(NodeId('local'), bus),
        timerPort: InMemoryTimePort(),
      );

      final timing = coordinator.getAdaptiveTimingStatus()!;

      expect(timing.smoothedRtt, equals(const Duration(milliseconds: 500)));
      expect(timing.rttVariance, equals(const Duration(milliseconds: 250)));
      expect(timing.rttSampleCount, equals(0));
      expect(timing.hasRttSamples, isFalse);
    });

    test('reports zero pending send count when idle', () async {
      final bus = InMemoryMessageBus();
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: NodeId('local')),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: InMemoryMessagePort(NodeId('local'), bus),
        timerPort: InMemoryTimePort(),
      );

      final timing = coordinator.getAdaptiveTimingStatus()!;

      expect(timing.totalPendingSendCount, equals(0));
    });
  });
}
