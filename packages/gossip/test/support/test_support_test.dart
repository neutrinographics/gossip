import 'dart:async';

import 'package:gossip/src/coordinator/coordinator.dart';
import 'package:gossip/src/coordinator/sync_state.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/sync/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';
import 'package:test/test.dart';

import 'coordinator_builder.dart';
import 'pump.dart';

void main() {
  group('createTestCoordinator', () {
    test('returns a usable coordinator with working defaults', () async {
      final coordinator = await createTestCoordinator();

      expect(coordinator.localNode, equals(NodeId('local')));
      expect(coordinator.state, equals(SyncState.stopped));
      expect(
        coordinator.hasNetworkSync,
        isFalse,
        reason:
            'omitting bus/timePort must reproduce Coordinator.create\'s '
            'own local-only default',
      );

      final channel = await coordinator.createChannel(ChannelId('ch1'));
      expect(channel.id, equals(ChannelId('ch1')));
    });

    test('nodeId overrides the default local node identity', () async {
      final coordinator = await createTestCoordinator(nodeId: 'peer-a');
      expect(coordinator.localNode, equals(NodeId('peer-a')));
    });

    test('supplying both nodeId and localNodeRepository throws '
        'ArgumentError', () {
      // The builder ignores nodeId when a repository is supplied (repository
      // identity wins, mirroring Coordinator.create). A caller passing both
      // believes nodeId took effect — reject the call instead of silently
      // honoring only half of it.
      expect(
        () => createTestCoordinator(
          nodeId: 'alice',
          localNodeRepository: InMemoryLocalNodeRepository(
            nodeId: NodeId('bob'),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('bus and timePort opt the coordinator into network sync', () async {
      final coordinator = await createTestCoordinator(
        bus: InMemoryMessageBus(),
        timePort: InMemoryTimePort(),
      );
      expect(coordinator.hasNetworkSync, isTrue);
    });

    test('start: true starts the coordinator before returning', () async {
      final coordinator = await createTestCoordinator(
        bus: InMemoryMessageBus(),
        timePort: InMemoryTimePort(),
        start: true,
      );
      expect(coordinator.state, equals(SyncState.running));
    });

    test(
      'recordedErrorsOf collects errors emitted when onError is omitted',
      () async {
        final coordinator = await createTestCoordinator();
        final channelId = ChannelId('ch1');
        final channel = await coordinator.createChannel(channelId);

        // Real error path (mirrors coordinator_error_wiring_test.dart):
        // remove the channel behind the held facade, then use it.
        await coordinator.removeChannel(channelId);
        await channel.addMember(NodeId('peer-1'));
        await pumpEventQueue();

        expect(recordedErrorsOf(coordinator), isNotEmpty);
      },
    );

    test(
      'an explicit onError receives errors instead of the recorded list',
      () async {
        final seen = <SyncError>[];
        final coordinator = await createTestCoordinator(onError: seen.add);
        final channelId = ChannelId('ch1');
        final channel = await coordinator.createChannel(channelId);

        await coordinator.removeChannel(channelId);
        await channel.addMember(NodeId('peer-1'));
        await pumpEventQueue();

        expect(seen, isNotEmpty);
        expect(
          () => recordedErrorsOf(coordinator),
          throwsStateError,
          reason:
              'an explicit onError takes over error handling entirely — '
              'there is nothing left for recordedErrorsOf to return',
        );
      },
    );
  });

  group('createTestCoordinator repository parameters', () {
    test('a caller-supplied channelRepository is actually used, not shadowed '
        'by a fresh internal instance', () async {
      final channelRepo = InMemoryChannelRepository();
      final channelId = ChannelId('pre-seeded');
      await channelRepo.save(
        ChannelAggregate(id: channelId, localNode: NodeId('local')),
      );

      final coordinator = await createTestCoordinator(
        channelRepository: channelRepo,
      );

      expect(
        coordinator.getChannel(channelId),
        isNotNull,
        reason:
            'the channel was pre-seeded into channelRepo before create; '
            'it is only visible if the builder passed this exact '
            'instance through to Coordinator.create instead of building '
            'its own',
      );
    });

    test('two createTestCoordinator calls sharing one channelRepository see '
        'the same data', () async {
      final channelRepo = InMemoryChannelRepository();
      final channelId = ChannelId('shared');

      final coordinator1 = await createTestCoordinator(
        channelRepository: channelRepo,
      );
      await coordinator1.createChannel(channelId);

      final coordinator2 = await createTestCoordinator(
        channelRepository: channelRepo,
      );

      expect(
        coordinator2.getChannel(channelId),
        isNotNull,
        reason:
            'coordinator2 was built with the same channelRepository '
            'instance coordinator1 wrote through, so it must load the '
            'channel coordinator1 created',
      );
    });
  });

  group('createTestCoordinator teardown', () {
    // Teardown fires after this test's body returns, i.e. between this
    // test and the next one in declaration order — so a coordinator built
    // here and inspected from the next test observes whether addTearDown
    // actually ran, which nothing inside a single test body can.
    Coordinator? previous;

    test('does not require a manual dispose() call', () async {
      previous = await createTestCoordinator();
      // Deliberately no dispose() here — addTearDown must handle it.
    });

    test("the previous test's coordinator was disposed by its teardown, "
        'and a second, manual dispose() is safe', () async {
      final coordinator = previous!;
      expect(
        coordinator.isDisposed,
        isTrue,
        reason:
            "addTearDown(dispose) from the prior test's builder call "
            'must have already run by the time this test starts',
      );

      await coordinator.dispose(); // must not throw on a second dispose

      expect(coordinator.isDisposed, isTrue);
    });
  });

  group('pumpUntil', () {
    test('returns immediately when the condition already holds', () async {
      // maxTurns: 0 forbids even a single event-loop turn, so this only
      // passes if the already-true condition short-circuits the poll.
      await pumpUntil(() => true, maxTurns: 0, describe: 'never needed');
    });

    test('polls across turns until the condition becomes true', () async {
      var flag = false;
      unawaited(
        Future<void>.delayed(Duration.zero).then((_) async {
          await Future<void>.delayed(Duration.zero);
          flag = true;
        }),
      );

      await pumpUntil(() => flag, describe: 'flag flips after a few turns');

      expect(flag, isTrue);
    });

    test(
      'fails with the descriptive message when the condition never holds',
      () async {
        await expectLater(
          pumpUntil(() => false, maxTurns: 3, describe: 'the impossible'),
          throwsA(
            isA<TestFailure>().having(
              (e) => e.message,
              'message',
              'pumpUntil gave up after 3 turns waiting for: the impossible',
            ),
          ),
        );
      },
    );
  });
}
