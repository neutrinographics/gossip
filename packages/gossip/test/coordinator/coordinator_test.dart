import 'dart:typed_data';
import 'package:gossip/src/shared/domain/events/domain_event.dart';
import 'package:gossip/src/sync/domain/events/sync_events.dart';
import 'package:gossip/src/membership/domain/events/membership_events.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/coordinator/coordinator.dart';
import 'package:gossip/src/coordinator/coordinator_config.dart';
import 'package:gossip/src/coordinator/sync_state.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/membership/infrastructure/in_memory_peer_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/membership/domain/value_objects/peer_status.dart';
import 'package:test/test.dart';

import '../support/coordinator_builder.dart';
import '../support/pump.dart';

void main() {
  group('Coordinator', () {
    late NodeId localNode;

    setUp(() {
      localNode = NodeId('local');
    });

    test('create returns coordinator with local node', () async {
      final coordinator = await createTestCoordinator();

      expect(coordinator.localNode, equals(localNode));
    });

    test('createChannel creates and returns channel facade', () async {
      final coordinator = await createTestCoordinator();

      final channelId = ChannelId('channel1');
      final channelFacade = await coordinator.createChannel(channelId);

      expect(channelFacade.id, equals(channelId));
    });

    test('createChannel emits ChannelCreated event', () async {
      final coordinator = await createTestCoordinator();

      final channelId = ChannelId('channel1');
      final events = <DomainEvent>[];
      coordinator.events.listen(events.add);

      await coordinator.createChannel(channelId);

      await pumpUntil(
        () => events.isNotEmpty,
        describe: 'the ChannelCreated event propagating',
      );

      expect(events.length, equals(1));
      expect(events.first, isA<ChannelCreated>());
      expect((events.first as ChannelCreated).channelId, equals(channelId));
    });

    test('getChannel returns null for non-existent channel', () async {
      final coordinator = await createTestCoordinator();

      final channelFacade = coordinator.getChannel(ChannelId('nonexistent'));
      expect(channelFacade, isNull);
    });

    test('getChannel returns facade for existing channel', () async {
      final coordinator = await createTestCoordinator();

      final channelId = ChannelId('channel1');
      await coordinator.createChannel(channelId);

      final channelFacade = coordinator.getChannel(channelId);
      expect(channelFacade, isNotNull);
      expect(channelFacade!.id, equals(channelId));
    });

    test('channelIds returns list of created channels', () async {
      final coordinator = await createTestCoordinator();

      final channelId1 = ChannelId('channel1');
      final channelId2 = ChannelId('channel2');
      await coordinator.createChannel(channelId1);
      await coordinator.createChannel(channelId2);

      final channelIds = coordinator.channelIds;
      expect(channelIds, contains(channelId1));
      expect(channelIds, contains(channelId2));
    });

    test('coordinator starts in stopped state', () async {
      final coordinator = await createTestCoordinator();

      expect(coordinator.state, equals(SyncState.stopped));
      expect(coordinator.isDisposed, isFalse);
    });

    test('start transitions from stopped to running', () async {
      final coordinator = await createTestCoordinator();

      await coordinator.start();

      expect(coordinator.state, equals(SyncState.running));
    });

    test('start is idempotent when already running', () async {
      final coordinator = await createTestCoordinator();

      await coordinator.start();
      await coordinator.start(); // Should not throw

      expect(coordinator.state, equals(SyncState.running));
    });

    test('stop transitions from running to stopped', () async {
      final coordinator = await createTestCoordinator();

      await coordinator.start();
      await coordinator.stop();

      expect(coordinator.state, equals(SyncState.stopped));
    });

    test('stop is idempotent when already stopped', () async {
      final coordinator = await createTestCoordinator();

      await coordinator.stop(); // Should not throw

      expect(coordinator.state, equals(SyncState.stopped));
    });

    test('pause transitions from running to paused', () async {
      final coordinator = await createTestCoordinator();

      await coordinator.start();
      await coordinator.pause();

      expect(coordinator.state, equals(SyncState.paused));
    });

    test('pause throws when not running', () async {
      final coordinator = await createTestCoordinator();

      expect(() => coordinator.pause(), throwsStateError);
    });

    test('resume transitions from paused to running', () async {
      final coordinator = await createTestCoordinator();

      await coordinator.start();
      await coordinator.pause();
      await coordinator.resume();

      expect(coordinator.state, equals(SyncState.running));
    });

    test('resume throws when not paused', () async {
      final coordinator = await createTestCoordinator();

      expect(() => coordinator.resume(), throwsStateError);
    });

    test('dispose transitions to disposed and closes streams', () async {
      final coordinator = await createTestCoordinator();

      // Dispose is the act under test — not builder-teardown cleanup.
      await coordinator.dispose();

      expect(coordinator.state, equals(SyncState.disposed));
      expect(coordinator.isDisposed, isTrue);
    });

    test('dispose is idempotent', () async {
      final coordinator = await createTestCoordinator();

      // Both calls are the act under test — not builder-teardown cleanup.
      await coordinator.dispose();
      await coordinator.dispose(); // Should not throw

      expect(coordinator.state, equals(SyncState.disposed));
    });

    test('dispose stops running coordinator', () async {
      final coordinator = await createTestCoordinator();

      await coordinator.start();
      // Dispose is the act under test — not builder-teardown cleanup.
      await coordinator.dispose();

      expect(coordinator.state, equals(SyncState.disposed));
    });

    test('start throws when disposed', () async {
      final coordinator = await createTestCoordinator();

      // Dispose is the act under test — not builder-teardown cleanup.
      await coordinator.dispose();

      expect(() => coordinator.start(), throwsStateError);
    });

    test('hasNetworkSync is false in local-only mode', () async {
      final coordinator = await createTestCoordinator();

      expect(coordinator.hasNetworkSync, isFalse);
    });

    test('hasNetworkSync is true when ports are provided', () async {
      final bus = InMemoryMessageBus();
      final coordinator = await createTestCoordinator(
        bus: bus,
        timePort: InMemoryTimePort(),
      );

      expect(coordinator.hasNetworkSync, isTrue);
    });

    group('stateChanges', () {
      test('emits running when started', () async {
        final coordinator = await createTestCoordinator();

        final states = <SyncState>[];
        coordinator.stateChanges.listen(states.add);

        await coordinator.start();
        await pumpUntil(
          () => states.isNotEmpty,
          describe: 'the running state change propagating',
        );

        expect(states, equals([SyncState.running]));
      });

      test('emits stopped when stopped', () async {
        final coordinator = await createTestCoordinator();

        final states = <SyncState>[];
        await coordinator.start();
        coordinator.stateChanges.listen(states.add);

        await coordinator.stop();
        await pumpUntil(
          () => states.isNotEmpty,
          describe: 'the stopped state change propagating',
        );

        expect(states, equals([SyncState.stopped]));
      });

      test('emits paused and running for pause/resume', () async {
        final coordinator = await createTestCoordinator();

        final states = <SyncState>[];
        coordinator.stateChanges.listen(states.add);

        await coordinator.start();
        await coordinator.pause();
        await coordinator.resume();
        await pumpUntil(
          () => states.length >= 3,
          describe: 'the running/paused/running state changes propagating',
        );

        expect(
          states,
          equals([SyncState.running, SyncState.paused, SyncState.running]),
        );
      });

      test('emits disposed on dispose', () async {
        final coordinator = await createTestCoordinator();

        final states = <SyncState>[];
        coordinator.stateChanges.listen(states.add);

        // Dispose is the act under test — not builder-teardown cleanup.
        await coordinator.dispose();
        await pumpUntil(
          () => states.isNotEmpty,
          describe: 'the disposed state change propagating',
        );

        expect(states, equals([SyncState.disposed]));
      });

      test('does not emit on idempotent start/stop', () async {
        final coordinator = await createTestCoordinator();

        final states = <SyncState>[];
        coordinator.stateChanges.listen(states.add);

        await coordinator.stop(); // Already stopped — no emit
        await coordinator.start();
        await coordinator.start(); // Already running — no emit
        await pumpUntil(
          () => states.isNotEmpty,
          describe: 'the running state change propagating',
        );

        expect(states, equals([SyncState.running]));
      });
    });

    group('destroy', () {
      test('transitions to disposed state', () async {
        final coordinator = await createTestCoordinator();

        await coordinator.start();
        await coordinator.destroy();

        expect(coordinator.state, equals(SyncState.disposed));
      });

      test('clears all repositories', () async {
        // holds each repository to assert it was cleared.
        final channelRepo = InMemoryChannelRepository();
        final peerRepo = InMemoryPeerRepository();
        final entryRepo = InMemoryEntryRepository();
        final localNodeRepo = InMemoryLocalNodeRepository(nodeId: localNode);

        final coordinator = await createTestCoordinator(
          localNodeRepository: localNodeRepo,
          channelRepository: channelRepo,
          peerRepository: peerRepo,
          entryRepository: entryRepo,
        );

        // Set up state
        final channelId = ChannelId('ch');
        final streamId = StreamId('s');
        final channel = await coordinator.createChannel(channelId);
        final stream = await channel.getOrCreateStream(streamId);
        await stream.append(Uint8List.fromList([1, 2, 3]));
        await coordinator.addPeer(NodeId('peer1'));

        // Verify state exists
        expect(await channelRepo.count, equals(1));
        expect(await peerRepo.count, equals(1));
        expect(await entryRepo.entryCount(channelId, streamId), equals(1));

        await coordinator.destroy();

        // All repos should be empty
        expect(await channelRepo.count, equals(0));
        expect(await peerRepo.count, equals(0));
        expect(await entryRepo.entryCount(channelId, streamId), equals(0));
      });

      test('resets local node identity', () async {
        // holds localNodeRepo to assert identity was cleared.
        final localNodeRepo = InMemoryLocalNodeRepository(nodeId: localNode);

        final coordinator = await createTestCoordinator(
          localNodeRepository: localNodeRepo,
        );

        await coordinator.destroy();

        // Node ID should be cleared so next create generates a new one
        expect(await localNodeRepo.getNodeId(), isNull);
        expect(await localNodeRepo.getClockState(), equals(Hlc.zero));
      });

      test('is idempotent', () async {
        final coordinator = await createTestCoordinator();

        await coordinator.destroy();
        await coordinator.destroy(); // Should not throw

        expect(coordinator.state, equals(SyncState.disposed));
      });

      test('emits disposed on stateChanges', () async {
        final coordinator = await createTestCoordinator();

        final states = <SyncState>[];
        coordinator.stateChanges.listen(states.add);

        await coordinator.destroy();
        await pumpUntil(
          () => states.isNotEmpty,
          describe: 'the disposed state change propagating',
        );

        expect(states, equals([SyncState.disposed]));
      });

      test('new coordinator after destroy gets fresh identity', () async {
        // shares repositories across two sequential creates.
        final channelRepo = InMemoryChannelRepository();
        final entryRepo = InMemoryEntryRepository();
        final localNodeRepo = InMemoryLocalNodeRepository(nodeId: localNode);

        final coord1 = await createTestCoordinator(
          localNodeRepository: localNodeRepo,
          channelRepository: channelRepo,
          entryRepository: entryRepo,
        );

        await coord1.createChannel(ChannelId('ch'));
        await coord1.destroy();

        // Create new coordinator — should get fresh identity
        final coord2 = await createTestCoordinator(
          localNodeRepository: localNodeRepo,
          channelRepository: channelRepo,
          entryRepository: entryRepo,
        );

        expect(coord2.localNode, isNot(equals(localNode)));
        expect(coord2.channelIds, isEmpty);
      });
    });

    test('events stream is available', () async {
      final coordinator = await createTestCoordinator();

      expect(coordinator.events, isA<Stream>());
    });

    test('errors stream is available', () async {
      final coordinator = await createTestCoordinator();

      expect(coordinator.errors, isA<Stream>());
    });

    test(
      'coordinator can be created with gossip engine and failure detector',
      () async {
        final bus = InMemoryMessageBus();
        final coordinator = await createTestCoordinator(
          bus: bus,
          timePort: InMemoryTimePort(),
        );

        expect(coordinator.localNode, equals(localNode));
        expect(coordinator.state, equals(SyncState.stopped));
      },
    );

    test('coordinator with protocols can start and stop', () async {
      final bus = InMemoryMessageBus();
      final coordinator = await createTestCoordinator(
        bus: bus,
        timePort: InMemoryTimePort(),
      );

      await coordinator.start();
      expect(coordinator.state, equals(SyncState.running));

      await coordinator.stop();
      expect(coordinator.state, equals(SyncState.stopped));
    });

    test('creating channel updates gossip engine when running', () async {
      final bus = InMemoryMessageBus();
      final coordinator = await createTestCoordinator(
        bus: bus,
        timePort: InMemoryTimePort(),
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
      final coordinator = await createTestCoordinator(
        bus: bus,
        timePort: InMemoryTimePort(),
      );

      await coordinator.start();
      expect(coordinator.state, equals(SyncState.running));

      await coordinator.pause();
      expect(coordinator.state, equals(SyncState.paused));

      await coordinator.resume();
      expect(coordinator.state, equals(SyncState.running));
    });

    test('addPeer adds peer to registry', () async {
      final coordinator = await createTestCoordinator();

      final peerId = NodeId('peer1');
      await coordinator.addPeer(peerId);

      expect(coordinator.peers.length, equals(1));
      expect(coordinator.peers.first.id, equals(peerId));
    });

    test('addPeer throws when adding local node', () async {
      final coordinator = await createTestCoordinator();

      expect(() => coordinator.addPeer(localNode), throwsException);
    });

    test('peer lifecycle events are emitted on the events stream', () async {
      final coordinator = await createTestCoordinator();

      final events = <DomainEvent>[];
      final sub = coordinator.events.listen(events.add);

      await coordinator.addPeer(NodeId('peer1'));
      await pumpUntil(
        () => events.whereType<PeerAdded>().isNotEmpty,
        describe: 'the PeerAdded event propagating',
      );
      expect(
        events.whereType<PeerAdded>().length,
        equals(1),
        reason: 'apps need peer lifecycle observability via events',
      );

      await coordinator.removePeer(NodeId('peer1'));
      await pumpUntil(
        () => events.whereType<PeerRemoved>().isNotEmpty,
        describe: 'the PeerRemoved event propagating',
      );
      expect(events.whereType<PeerRemoved>().length, equals(1));

      await sub.cancel();
    });

    test('removePeer clears the peer\'s probing hold', () async {
      final bus = InMemoryMessageBus();
      final coordinator = await createTestCoordinator(
        bus: bus,
        timePort: InMemoryTimePort(),
      );

      final peerId = NodeId('peer1');
      await coordinator.addPeer(peerId); // sets the startup grace hold
      final detector = coordinator.failureDetectorForTesting!;
      expect(detector.hasProbingHold(peerId), isTrue);

      await coordinator.removePeer(peerId);
      expect(
        detector.hasProbingHold(peerId),
        isFalse,
        reason: 'stale holds accumulate unbounded under peer churn',
      );
    });

    test('addPeer\'s startup grace hold expires on its own once '
        'startupGracePeriod elapses, making the peer probable again', () async {
      final bus = InMemoryMessageBus();
      final timePort = InMemoryTimePort();
      final coordinator = await createTestCoordinator(
        bus: bus,
        timePort: timePort,
        config: const CoordinatorConfig(
          startupGracePeriod: Duration(seconds: 5),
        ),
      );

      final peerId = NodeId('peer1');
      await coordinator.addPeer(peerId);
      final detector = coordinator.failureDetectorForTesting!;
      expect(detector.hasProbingHold(peerId), isTrue);
      expect(
        detector.nextProbeTarget(),
        isNull,
        reason: 'a peer under grace hold must not be selected for probing',
      );

      await timePort.advance(const Duration(seconds: 5, milliseconds: 1));

      expect(
        detector.hasProbingHold(peerId),
        isFalse,
        reason:
            'a peer whose grace hold never expires would never be '
            'probed for failure again',
      );
      expect(detector.nextProbeTarget()?.id, equals(peerId));
    });

    test('removePeer removes peer from registry', () async {
      final coordinator = await createTestCoordinator();

      final peerId = NodeId('peer1');
      await coordinator.addPeer(peerId);
      expect(coordinator.peers.length, equals(1));

      await coordinator.removePeer(peerId);
      expect(coordinator.peers.length, equals(0));
    });

    test('peers returns all registered peers', () async {
      final coordinator = await createTestCoordinator();

      final peer1 = NodeId('peer1');
      final peer2 = NodeId('peer2');
      await coordinator.addPeer(peer1);
      await coordinator.addPeer(peer2);

      final allPeers = coordinator.peers;
      expect(allPeers.length, equals(2));
      expect(allPeers.map((p) => p.id), containsAll([peer1, peer2]));
    });

    test('reachablePeers returns only reachable peers', () async {
      // bus + timePort wire up a FailureDetector so peerRegistry (and its
      // status transitions) is reachable via failureDetectorForTesting.
      final coordinator = await createTestCoordinator(
        bus: InMemoryMessageBus(),
        timePort: InMemoryTimePort(),
      );

      final peer1 = NodeId('peer1');
      final peer2 = NodeId('peer2');
      await coordinator.addPeer(peer1);
      await coordinator.addPeer(peer2);
      coordinator.failureDetectorForTesting!.peerRegistry.updatePeerStatus(
        peer2,
        PeerStatus.unreachable,
        occurredAt: DateTime.now(),
      );

      expect(coordinator.reachablePeers.length, equals(1));
      expect(coordinator.reachablePeers.first.id, equals(peer1));
    });

    test('getPeerMetrics returns metrics for peer', () async {
      final coordinator = await createTestCoordinator();

      final peerId = NodeId('peer1');
      await coordinator.addPeer(peerId);

      final metrics = coordinator.getPeerMetrics(peerId);
      expect(metrics, isNotNull);
      expect(metrics!.messagesReceived, equals(0));
      expect(metrics.messagesSent, equals(0));
    });

    test('getPeerMetrics returns null for unknown peer', () async {
      final coordinator = await createTestCoordinator();

      final metrics = coordinator.getPeerMetrics(NodeId('unknown'));
      expect(metrics, isNull);
    });

    test(
      'coordinator loads existing channels from repository on create',
      () async {
        // shares channelRepo across two sequential creates.
        final channelRepo = InMemoryChannelRepository();
        final coordinator1 = await createTestCoordinator(
          channelRepository: channelRepo,
        );

        final channelId = ChannelId('existing-channel');
        await coordinator1.createChannel(channelId);

        // Create a new coordinator instance with same repository
        // It should load the existing channel
        final coordinator2 = await createTestCoordinator(
          channelRepository: channelRepo,
        );

        // The channel should be accessible without recreating it
        final channel = coordinator2.getChannel(channelId);
        expect(channel, isNotNull);
        expect(channel!.id, equals(channelId));
      },
    );

    test('coordinator channelIds includes loaded channels', () async {
      // shares channelRepo across two sequential creates.
      final channelRepo = InMemoryChannelRepository();
      final coordinator1 = await createTestCoordinator(
        channelRepository: channelRepo,
      );

      final channel1 = ChannelId('channel1');
      final channel2 = ChannelId('channel2');
      await coordinator1.createChannel(channel1);
      await coordinator1.createChannel(channel2);

      // Create new coordinator with same repository
      final coordinator2 = await createTestCoordinator(
        channelRepository: channelRepo,
      );

      // channelIds should include loaded channels
      expect(coordinator2.channelIds, containsAll([channel1, channel2]));
    });

    test('create throws when localNode is empty', () async {
      expect(() => createTestCoordinator(nodeId: ''), throwsArgumentError);
    });

    test('create throws when channelRepository is null', () async {
      // Direct call: proves Coordinator.create's own null-argument
      // validation — the builder always supplies every repository.
      expect(
        () => Coordinator.create(
          localNodeRepository: InMemoryLocalNodeRepository(
            nodeId: NodeId('local'),
          ),
          channelRepository: null as dynamic,
          peerRepository: InMemoryPeerRepository(),
          entryRepository: InMemoryEntryRepository(),
        ),
        throwsA(isA<TypeError>()),
      );
    });

    test('create uses InMemoryPeerRepository by default', () async {
      // Direct call: proves Coordinator.create's own
      // `peerRepository ??= InMemoryPeerRepository()` default fires when
      // omitted — the builder always passes peerRepository explicitly.
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(
          nodeId: NodeId('local'),
        ),
        channelRepository: InMemoryChannelRepository(),
        entryRepository: InMemoryEntryRepository(),
      );

      // Should work without providing peerRepository
      await coordinator.addPeer(NodeId('peer1'));
      expect(coordinator.peers.length, equals(1));
    });

    test('create throws when entryRepository is null', () async {
      // Direct call: proves Coordinator.create's own null-argument
      // validation — the builder always supplies every repository.
      expect(
        () => Coordinator.create(
          localNodeRepository: InMemoryLocalNodeRepository(
            nodeId: NodeId('local'),
          ),
          channelRepository: InMemoryChannelRepository(),
          peerRepository: InMemoryPeerRepository(),
          entryRepository: null as dynamic,
        ),
        throwsA(isA<TypeError>()),
      );
    });

    test('create accepts custom config', () async {
      // 7 collides with neither CoordinatorConfig.suspicionThreshold's own
      // default (5) nor FailureDetector.failureThreshold's independent
      // default (3) — a value of 3 or 5 here would let the assertion
      // below pass even if the config were silently dropped and the
      // detector fell back to its own hardcoded default.
      final config = CoordinatorConfig(suspicionThreshold: 7);

      final messageBus = InMemoryMessageBus();
      final coordinator = await createTestCoordinator(
        bus: messageBus,
        timePort: InMemoryTimePort(),
        config: config,
      );

      expect(coordinator.localNode, equals(localNode));
      expect(coordinator.state, equals(SyncState.stopped));
      // The config must actually reach the component that consumes it,
      // not just get accepted and ignored.
      expect(
        coordinator.failureDetectorForTesting!.failureThreshold,
        equals(7),
      );
    });

    test('create uses default config when not specified', () async {
      final messageBus = InMemoryMessageBus();
      final coordinator = await createTestCoordinator(
        bus: messageBus,
        timePort: InMemoryTimePort(),
      );

      // Coordinator should be created successfully with default config
      expect(coordinator.localNode, equals(localNode));
      expect(coordinator.state, equals(SyncState.stopped));
    });

    group('removeChannel', () {
      test('removes channel from coordinator', () async {
        final coordinator = await createTestCoordinator();

        final channelId = ChannelId('channel1');
        await coordinator.createChannel(channelId);
        expect(coordinator.getChannel(channelId), isNotNull);

        final removed = await coordinator.removeChannel(channelId);

        expect(removed, isTrue);
        expect(coordinator.getChannel(channelId), isNull);
        expect(coordinator.channelIds, isNot(contains(channelId)));
      });

      test('removes channel entries from store', () async {
        // holds entryRepo to assert entries were removed.
        final entryRepo = InMemoryEntryRepository();
        final coordinator = await createTestCoordinator(
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
        final coordinator = await createTestCoordinator();

        final removed = await coordinator.removeChannel(
          ChannelId('nonexistent'),
        );

        expect(removed, isFalse);
      });

      test('emits ChannelRemoved event', () async {
        final coordinator = await createTestCoordinator();

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
        final coordinator = await createTestCoordinator(
          bus: bus,
          timePort: InMemoryTimePort(),
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
        final coordinator = await createTestCoordinator();

        final events = <DomainEvent>[];
        coordinator.events.listen(events.add);

        await coordinator.removeChannel(ChannelId('nonexistent'));

        expect(events, isEmpty);
      });
    });

    group('local node state persistence', () {
      group('currentClockState', () {
        test('returns null when no TimePort provided', () async {
          final coordinator = await createTestCoordinator();

          expect(coordinator.currentClockState, isNull);
        });

        test(
          'returns Hlc.zero when TimePort provided but no activity',
          () async {
            final bus = InMemoryMessageBus();
            final coordinator = await createTestCoordinator(
              bus: bus,
              timePort: InMemoryTimePort(),
            );

            expect(coordinator.currentClockState, equals(Hlc.zero));
          },
        );
      });

      group('clock state restoration', () {
        test('restores clock state from LocalNodeRepository', () async {
          // pre-seeds localNodeRepo before create() runs.
          final bus = InMemoryMessageBus();
          final localNodeRepo = InMemoryLocalNodeRepository(nodeId: localNode);
          await localNodeRepo.saveClockState(Hlc(5000, 42));

          final coordinator = await createTestCoordinator(
            localNodeRepository: localNodeRepo,
            bus: bus,
            timePort: InMemoryTimePort(),
          );

          expect(coordinator.currentClockState, equals(Hlc(5000, 42)));
        });

        test('persists clock state after appending entry', () async {
          // holds localNodeRepo to assert the persisted state.
          final bus = InMemoryMessageBus();
          final localNodeRepo = InMemoryLocalNodeRepository(nodeId: localNode);
          final timePort = InMemoryTimePort();
          timePort.advance(Duration(milliseconds: 1000));

          final coordinator = await createTestCoordinator(
            localNodeRepository: localNodeRepo,
            bus: bus,
            timePort: timePort,
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
            // pre-seeds localNodeRepo before create() runs.
            final localNodeRepo = InMemoryLocalNodeRepository(
              nodeId: localNode,
            );
            await localNodeRepo.saveClockState(Hlc(5000, 42));

            final coordinator = await createTestCoordinator(
              localNodeRepository: localNodeRepo,
            );

            expect(coordinator.currentClockState, isNull);
          },
        );
      });

      group('round-trip persistence', () {
        test('clock survives across coordinator creates', () async {
          // shares repositories across two sequential creates.
          final bus = InMemoryMessageBus();
          final channelRepo = InMemoryChannelRepository();
          final entryRepo = InMemoryEntryRepository();
          final localNodeRepo = InMemoryLocalNodeRepository(nodeId: localNode);
          final timePort = InMemoryTimePort();
          timePort.advance(Duration(milliseconds: 1000));

          // First session: write entries
          final coord1 = await createTestCoordinator(
            localNodeRepository: localNodeRepo,
            channelRepository: channelRepo,
            entryRepository: entryRepo,
            bus: bus,
            timePort: timePort,
          );

          final channel = await coord1.createChannel(ChannelId('ch'));
          final stream = await channel.getOrCreateStream(StreamId('s'));
          await stream.append(Uint8List.fromList([1, 2, 3]));

          final savedClock = coord1.currentClockState;

          // Second session: restore from same repositories
          final coord2 = await createTestCoordinator(
            localNodeRepository: localNodeRepo,
            channelRepository: channelRepo,
            entryRepository: entryRepo,
            bus: bus,
            timePort: InMemoryTimePort(),
          );

          expect(coord2.currentClockState, equals(savedClock));
        });
      });
    });
  });
}
