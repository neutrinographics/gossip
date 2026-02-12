import 'dart:typed_data';
import 'package:gossip/src/domain/events/domain_event.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/facade/coordinator.dart';
import 'package:gossip/src/facade/coordinator_config.dart';
import 'package:gossip/src/facade/sync_state.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_channel_repository.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_local_node_repository.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_peer_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:test/test.dart';

void main() {
  group('Coordinator', () {
    late NodeId localNode;

    setUp(() {
      localNode = NodeId('local');
    });

    test('create returns coordinator with local node', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      expect(coordinator.localNode, equals(localNode));
    });

    test('createChannel creates and returns channel facade', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final channelId = ChannelId('channel1');
      final channelFacade = await coordinator.createChannel(channelId);

      expect(channelFacade.id, equals(channelId));
    });

    test('createChannel emits ChannelCreated event', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final channelId = ChannelId('channel1');
      final events = <DomainEvent>[];
      coordinator.events.listen(events.add);

      await coordinator.createChannel(channelId);

      // Allow event to propagate
      await Future.delayed(Duration.zero);

      expect(events.length, equals(1));
      expect(events.first, isA<ChannelCreated>());
      expect((events.first as ChannelCreated).channelId, equals(channelId));
    });

    test('getChannel returns null for non-existent channel', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final channelFacade = coordinator.getChannel(ChannelId('nonexistent'));
      expect(channelFacade, isNull);
    });

    test('getChannel returns facade for existing channel', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final channelId = ChannelId('channel1');
      await coordinator.createChannel(channelId);

      final channelFacade = coordinator.getChannel(channelId);
      expect(channelFacade, isNotNull);
      expect(channelFacade!.id, equals(channelId));
    });

    test('channelIds returns list of created channels', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final channelId1 = ChannelId('channel1');
      final channelId2 = ChannelId('channel2');
      await coordinator.createChannel(channelId1);
      await coordinator.createChannel(channelId2);

      final channelIds = coordinator.channelIds;
      expect(channelIds, contains(channelId1));
      expect(channelIds, contains(channelId2));
    });

    test('coordinator starts in stopped state', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      expect(coordinator.state, equals(SyncState.stopped));
      expect(coordinator.isDisposed, isFalse);
    });

    test('start transitions from stopped to running', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.start();

      expect(coordinator.state, equals(SyncState.running));
    });

    test('start throws when already running', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.start();

      expect(() => coordinator.start(), throwsStateError);
    });

    test('stop transitions from running to stopped', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.start();
      await coordinator.stop();

      expect(coordinator.state, equals(SyncState.stopped));
    });

    test('stop throws when already stopped', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      expect(() => coordinator.stop(), throwsStateError);
    });

    test('pause transitions from running to paused', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.start();
      await coordinator.pause();

      expect(coordinator.state, equals(SyncState.paused));
    });

    test('pause throws when not running', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      expect(() => coordinator.pause(), throwsStateError);
    });

    test('resume transitions from paused to running', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.start();
      await coordinator.pause();
      await coordinator.resume();

      expect(coordinator.state, equals(SyncState.running));
    });

    test('resume throws when not paused', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      expect(() => coordinator.resume(), throwsStateError);
    });

    test('dispose transitions to disposed and closes streams', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.dispose();

      expect(coordinator.state, equals(SyncState.disposed));
      expect(coordinator.isDisposed, isTrue);
    });

    test('dispose is idempotent', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.dispose();
      await coordinator.dispose(); // Should not throw

      expect(coordinator.state, equals(SyncState.disposed));
    });

    test('dispose stops running coordinator', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.start();
      await coordinator.dispose();

      expect(coordinator.state, equals(SyncState.disposed));
    });

    test('start throws when disposed', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      await coordinator.dispose();

      expect(() => coordinator.start(), throwsStateError);
    });

    test('events stream is available', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      expect(coordinator.events, isA<Stream>());
    });

    test('errors stream is available', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      expect(coordinator.errors, isA<Stream>());
    });

    test(
      'coordinator can be created with gossip engine and failure detector',
      () async {
        final bus = InMemoryMessageBus();
        final coordinator = await Coordinator.create(
          localNode: localNode,
          channelRepository: InMemoryChannelRepository(),
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
          messagePort: InMemoryMessagePort(localNode, bus),
          timerPort: InMemoryTimePort(),
        );

        expect(coordinator.localNode, equals(localNode));
        expect(coordinator.state, equals(SyncState.stopped));
      },
    );

    test('coordinator with protocols can start and stop', () async {
      final bus = InMemoryMessageBus();
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: InMemoryMessagePort(localNode, bus),
        timerPort: InMemoryTimePort(),
      );

      await coordinator.start();
      expect(coordinator.state, equals(SyncState.running));

      await coordinator.stop();
      expect(coordinator.state, equals(SyncState.stopped));
    });

    test('creating channel updates gossip engine when running', () async {
      final bus = InMemoryMessageBus();
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: InMemoryMessagePort(localNode, bus),
        timerPort: InMemoryTimePort(),
      );

      await coordinator.start();

      // Create channel while running - should update gossip engine
      final channelId = ChannelId('test-channel');
      final channel = await coordinator.createChannel(channelId);

      expect(channel.id, equals(channelId));
      expect(coordinator.state, equals(SyncState.running));
    });

    test('coordinator with protocols can pause and resume', () async {
      final bus = InMemoryMessageBus();
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: InMemoryMessagePort(localNode, bus),
        timerPort: InMemoryTimePort(),
      );

      await coordinator.start();
      expect(coordinator.state, equals(SyncState.running));

      await coordinator.pause();
      expect(coordinator.state, equals(SyncState.paused));

      await coordinator.resume();
      expect(coordinator.state, equals(SyncState.running));
    });

    test('addPeer adds peer to registry', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final peerId = NodeId('peer1');
      await coordinator.addPeer(peerId);

      expect(coordinator.peers.length, equals(1));
      expect(coordinator.peers.first.id, equals(peerId));
    });

    test('addPeer throws when adding local node', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      expect(() => coordinator.addPeer(localNode), throwsException);
    });

    test('removePeer removes peer from registry', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final peerId = NodeId('peer1');
      await coordinator.addPeer(peerId);
      expect(coordinator.peers.length, equals(1));

      await coordinator.removePeer(peerId);
      expect(coordinator.peers.length, equals(0));
    });

    test('peers returns all registered peers', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final peer1 = NodeId('peer1');
      final peer2 = NodeId('peer2');
      await coordinator.addPeer(peer1);
      await coordinator.addPeer(peer2);

      final allPeers = coordinator.peers;
      expect(allPeers.length, equals(2));
      expect(allPeers.map((p) => p.id), containsAll([peer1, peer2]));
    });

    test('reachablePeers returns only reachable peers', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final peer1 = NodeId('peer1');
      await coordinator.addPeer(peer1);

      expect(coordinator.reachablePeers.length, equals(1));
      expect(coordinator.reachablePeers.first.id, equals(peer1));
    });

    test('localIncarnation returns peer registry incarnation', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      expect(coordinator.localIncarnation, equals(0));
    });

    test('getPeerMetrics returns metrics for peer', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final peerId = NodeId('peer1');
      await coordinator.addPeer(peerId);

      final metrics = coordinator.getPeerMetrics(peerId);
      expect(metrics, isNotNull);
      expect(metrics!.messagesReceived, equals(0));
      expect(metrics.messagesSent, equals(0));
    });

    test('getPeerMetrics returns null for unknown peer', () async {
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final metrics = coordinator.getPeerMetrics(NodeId('unknown'));
      expect(metrics, isNull);
    });

    test(
      'coordinator loads existing channels from repository on create',
      () async {
        // Create a channel and persist it
        final channelRepo = InMemoryChannelRepository();
        final coordinator1 = await Coordinator.create(
          localNode: localNode,
          channelRepository: channelRepo,
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
        );

        final channelId = ChannelId('existing-channel');
        await coordinator1.createChannel(channelId);

        // Create a new coordinator instance with same repository
        // It should load the existing channel
        final coordinator2 = await Coordinator.create(
          localNode: localNode,
          channelRepository: channelRepo,
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
        );

        // The channel should be accessible without recreating it
        final channel = coordinator2.getChannel(channelId);
        expect(channel, isNotNull);
        expect(channel!.id, equals(channelId));
      },
    );

    test('coordinator channelIds includes loaded channels', () async {
      // Create channels and persist them
      final channelRepo = InMemoryChannelRepository();
      final coordinator1 = await Coordinator.create(
        localNode: localNode,
        channelRepository: channelRepo,
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      final channel1 = ChannelId('channel1');
      final channel2 = ChannelId('channel2');
      await coordinator1.createChannel(channel1);
      await coordinator1.createChannel(channel2);

      // Create new coordinator with same repository
      final coordinator2 = await Coordinator.create(
        localNode: localNode,
        channelRepository: channelRepo,
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      // channelIds should include loaded channels
      expect(coordinator2.channelIds, containsAll([channel1, channel2]));
    });

    test('create throws when localNode is empty', () async {
      expect(
        () => Coordinator.create(
          localNode: NodeId(''),
          channelRepository: InMemoryChannelRepository(),
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
        ),
        throwsArgumentError,
      );
    });

    test('create throws when channelRepository is null', () async {
      expect(
        () => Coordinator.create(
          localNode: NodeId('local'),
          channelRepository: null as dynamic,
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
        ),
        throwsA(isA<TypeError>()),
      );
    });

    test('create throws when peerRepository is null', () async {
      expect(
        () => Coordinator.create(
          localNode: NodeId('local'),
          channelRepository: InMemoryChannelRepository(),
          peerRepository: null as dynamic,
          entryRepository: InMemoryEntryRepository(),
        ),
        throwsA(isA<TypeError>()),
      );
    });

    test('create throws when entryRepository is null', () async {
      expect(
        () => Coordinator.create(
          localNode: NodeId('local'),
          channelRepository: InMemoryChannelRepository(),
          peerRepository: InMemoryPeerRepository(),
          entryRepository: null as dynamic,
        ),
        throwsA(isA<TypeError>()),
      );
    });

    test('create accepts custom config', () async {
      final config = CoordinatorConfig(suspicionThreshold: 3);

      final messageBus = InMemoryMessageBus();
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: InMemoryMessagePort(localNode, messageBus),
        timerPort: InMemoryTimePort(),
        config: config,
      );

      // Coordinator should be created successfully with custom config
      expect(coordinator.localNode, equals(localNode));
      expect(coordinator.state, equals(SyncState.stopped));
    });

    test('create uses default config when not specified', () async {
      final messageBus = InMemoryMessageBus();
      final coordinator = await Coordinator.create(
        localNode: localNode,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: InMemoryMessagePort(localNode, messageBus),
        timerPort: InMemoryTimePort(),
      );

      // Coordinator should be created successfully with default config
      expect(coordinator.localNode, equals(localNode));
      expect(coordinator.state, equals(SyncState.stopped));
    });

    group('removeChannel', () {
      test('removes channel from coordinator', () async {
        final coordinator = await Coordinator.create(
          localNode: localNode,
          channelRepository: InMemoryChannelRepository(),
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
        );

        final channelId = ChannelId('channel1');
        await coordinator.createChannel(channelId);
        expect(coordinator.getChannel(channelId), isNotNull);

        final removed = await coordinator.removeChannel(channelId);

        expect(removed, isTrue);
        expect(coordinator.getChannel(channelId), isNull);
        expect(coordinator.channelIds, isNot(contains(channelId)));
      });

      test('removes channel entries from store', () async {
        final entryRepo = InMemoryEntryRepository();
        final coordinator = await Coordinator.create(
          localNode: localNode,
          channelRepository: InMemoryChannelRepository(),
          peerRepository: InMemoryPeerRepository(),
          entryRepository: entryRepo,
        );

        final channelId = ChannelId('channel1');
        final streamId = StreamId('stream1');
        final channel = await coordinator.createChannel(channelId);
        final stream = await channel.getOrCreateStream(streamId);
        await stream.append(Uint8List.fromList([1, 2, 3]));

        expect(await entryRepo.getAll(channelId, streamId), hasLength(1));

        await coordinator.removeChannel(channelId);

        expect(await entryRepo.getAll(channelId, streamId), isEmpty);
      });

      test('returns false for non-existent channel', () async {
        final coordinator = await Coordinator.create(
          localNode: localNode,
          channelRepository: InMemoryChannelRepository(),
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
        );

        final removed = await coordinator.removeChannel(
          ChannelId('nonexistent'),
        );

        expect(removed, isFalse);
      });

      test('emits ChannelRemoved event', () async {
        final coordinator = await Coordinator.create(
          localNode: localNode,
          channelRepository: InMemoryChannelRepository(),
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
        );

        final channelId = ChannelId('channel1');
        await coordinator.createChannel(channelId);

        // Subscribe to events before removing
        final eventsFuture = coordinator.events.first;

        await coordinator.removeChannel(channelId);

        final event = await eventsFuture;
        expect(event, isA<ChannelRemoved>());
        expect((event as ChannelRemoved).channelId, equals(channelId));
      });

      test('updates gossip engine when running', () async {
        final bus = InMemoryMessageBus();
        final coordinator = await Coordinator.create(
          localNode: localNode,
          channelRepository: InMemoryChannelRepository(),
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
          messagePort: InMemoryMessagePort(localNode, bus),
          timerPort: InMemoryTimePort(),
        );

        final channelId = ChannelId('channel1');
        await coordinator.createChannel(channelId);
        await coordinator.start();

        // Remove channel while running - should update gossip engine
        final removed = await coordinator.removeChannel(channelId);

        expect(removed, isTrue);
        expect(coordinator.getChannel(channelId), isNull);
        expect(coordinator.state, equals(SyncState.running));
      });

      test('does not emit event when channel does not exist', () async {
        final coordinator = await Coordinator.create(
          localNode: localNode,
          channelRepository: InMemoryChannelRepository(),
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
        );

        final events = <DomainEvent>[];
        coordinator.events.listen(events.add);

        await coordinator.removeChannel(ChannelId('nonexistent'));

        expect(events, isEmpty);
      });
    });

    group('local node state persistence', () {
      group('currentClockState', () {
        test('returns null when no TimePort provided', () async {
          final coordinator = await Coordinator.create(
            localNode: localNode,
            channelRepository: InMemoryChannelRepository(),
            peerRepository: InMemoryPeerRepository(),
            entryRepository: InMemoryEntryRepository(),
          );

          expect(coordinator.currentClockState, isNull);
        });

        test(
          'returns Hlc.zero when TimePort provided but no activity',
          () async {
            final bus = InMemoryMessageBus();
            final coordinator = await Coordinator.create(
              localNode: localNode,
              channelRepository: InMemoryChannelRepository(),
              peerRepository: InMemoryPeerRepository(),
              entryRepository: InMemoryEntryRepository(),
              messagePort: InMemoryMessagePort(localNode, bus),
              timerPort: InMemoryTimePort(),
            );

            expect(coordinator.currentClockState, equals(Hlc.zero));
          },
        );
      });

      group('clock state restoration', () {
        test('restores clock state from LocalNodeRepository', () async {
          final bus = InMemoryMessageBus();
          final localNodeRepo = InMemoryLocalNodeRepository();
          await localNodeRepo.saveClockState(Hlc(5000, 42));

          final coordinator = await Coordinator.create(
            localNode: localNode,
            channelRepository: InMemoryChannelRepository(),
            peerRepository: InMemoryPeerRepository(),
            entryRepository: InMemoryEntryRepository(),
            localNodeRepository: localNodeRepo,
            messagePort: InMemoryMessagePort(localNode, bus),
            timerPort: InMemoryTimePort(),
          );

          expect(coordinator.currentClockState, equals(Hlc(5000, 42)));
        });

        test('persists clock state after appending entry', () async {
          final bus = InMemoryMessageBus();
          final localNodeRepo = InMemoryLocalNodeRepository();
          final timePort = InMemoryTimePort();
          timePort.advance(Duration(milliseconds: 1000));

          final coordinator = await Coordinator.create(
            localNode: localNode,
            channelRepository: InMemoryChannelRepository(),
            peerRepository: InMemoryPeerRepository(),
            entryRepository: InMemoryEntryRepository(),
            localNodeRepository: localNodeRepo,
            messagePort: InMemoryMessagePort(localNode, bus),
            timerPort: timePort,
          );

          final channel = await coordinator.createChannel(ChannelId('ch'));
          final stream = await channel.getOrCreateStream(StreamId('s'));
          await stream.append(Uint8List.fromList([1, 2, 3]));

          final savedState = await localNodeRepo.getClockState();
          expect(savedState, greaterThan(Hlc.zero));
          expect(savedState, equals(coordinator.currentClockState));
        });

        test(
          'ignores LocalNodeRepository clock state without TimePort',
          () async {
            final localNodeRepo = InMemoryLocalNodeRepository();
            await localNodeRepo.saveClockState(Hlc(5000, 42));

            final coordinator = await Coordinator.create(
              localNode: localNode,
              channelRepository: InMemoryChannelRepository(),
              peerRepository: InMemoryPeerRepository(),
              entryRepository: InMemoryEntryRepository(),
              localNodeRepository: localNodeRepo,
            );

            expect(coordinator.currentClockState, isNull);
          },
        );
      });

      group('incarnation restoration', () {
        test('restores incarnation from LocalNodeRepository', () async {
          final localNodeRepo = InMemoryLocalNodeRepository();
          await localNodeRepo.saveIncarnation(5);

          final coordinator = await Coordinator.create(
            localNode: localNode,
            channelRepository: InMemoryChannelRepository(),
            peerRepository: InMemoryPeerRepository(),
            entryRepository: InMemoryEntryRepository(),
            localNodeRepository: localNodeRepo,
          );

          expect(coordinator.localIncarnation, equals(5));
        });

        test('defaults incarnation to 0 without LocalNodeRepository', () async {
          final coordinator = await Coordinator.create(
            localNode: localNode,
            channelRepository: InMemoryChannelRepository(),
            peerRepository: InMemoryPeerRepository(),
            entryRepository: InMemoryEntryRepository(),
          );

          expect(coordinator.localIncarnation, equals(0));
        });
      });

      group('round-trip persistence', () {
        test(
          'clock and incarnation survive across coordinator creates',
          () async {
            final bus = InMemoryMessageBus();
            final channelRepo = InMemoryChannelRepository();
            final entryRepo = InMemoryEntryRepository();
            final localNodeRepo = InMemoryLocalNodeRepository();
            final timePort = InMemoryTimePort();
            timePort.advance(Duration(milliseconds: 1000));

            // First session: write entries
            final coord1 = await Coordinator.create(
              localNode: localNode,
              channelRepository: channelRepo,
              peerRepository: InMemoryPeerRepository(),
              entryRepository: entryRepo,
              localNodeRepository: localNodeRepo,
              messagePort: InMemoryMessagePort(localNode, bus),
              timerPort: timePort,
            );

            final channel = await coord1.createChannel(ChannelId('ch'));
            final stream = await channel.getOrCreateStream(StreamId('s'));
            await stream.append(Uint8List.fromList([1, 2, 3]));

            final savedClock = coord1.currentClockState;
            final savedIncarnation = coord1.localIncarnation;

            // Second session: restore from same repositories
            final coord2 = await Coordinator.create(
              localNode: localNode,
              channelRepository: channelRepo,
              peerRepository: InMemoryPeerRepository(),
              entryRepository: entryRepo,
              localNodeRepository: localNodeRepo,
              messagePort: InMemoryMessagePort(localNode, bus),
              timerPort: InMemoryTimePort(),
            );

            expect(coord2.currentClockState, equals(savedClock));
            expect(coord2.localIncarnation, equals(savedIncarnation));
          },
        );
      });
    });
  });
}
