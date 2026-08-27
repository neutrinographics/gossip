import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/domain/interfaces/state_materializer.dart';
import 'package:gossip/src/coordinator/coordinator.dart';
import 'package:gossip/src/coordinator/coordinator_config.dart';
import 'package:gossip/src/coordinator/sync_state.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/shared/domain/interfaces/message_port.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/membership/infrastructure/in_memory_peer_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:test/test.dart';

import '../support/coordinator_builder.dart';
import '../support/pump.dart';

class _CountMaterializer extends StateMaterializer<int> {
  @override
  (int, String?) initial({required bool isReset}) => (0, null);

  @override
  int fold(int state, LogEntry entry) => state + 1;
}

// Every test in this file wants network sync active on a fast, fixed
// clock — the default local-only builder config would leave the gossip
// engine and failure detector absent, and the adaptive-timing defaults
// would make the interleaving/timing assertions below flaky.
const _fastNetworkConfig = CoordinatorConfig(
  gossipInterval: Duration(milliseconds: 100),
  probeInterval: Duration(milliseconds: 100),
  pingTimeout: Duration(milliseconds: 50),
  startupGracePeriod: Duration.zero,
);

void main() {
  final localNode = NodeId('local');

  group('Coordinator start/stop interleaving', () {
    test(
      'stop() during an in-flight start() wins — engines never run',
      () async {
        final coordinator = await createTestCoordinator(
          bus: InMemoryMessageBus(),
          timePort: InMemoryTimePort(),
          config: _fastNetworkConfig,
        );

        // start() suspends internally (channel loading) before starting the
        // engines. A stop() issued during that window is the LAST call and
        // must win: the coordinator must not end up with live engines.
        final startFuture = coordinator.start();
        await coordinator.stop();
        await startFuture;

        expect(coordinator.state, equals(SyncState.stopped));
        expect(
          coordinator.gossipEngineForTesting!.isRunning,
          isFalse,
          reason: 'a stopped coordinator must not gossip in the background',
        );
        expect(
          coordinator.failureDetectorForTesting!.isRunning,
          isFalse,
          reason: 'a stopped coordinator must not probe in the background',
        );
      },
    );

    test(
      'state always matches engine liveness after start/stop churn',
      () async {
        final coordinator = await createTestCoordinator(
          bus: InMemoryMessageBus(),
          timePort: InMemoryTimePort(),
          config: _fastNetworkConfig,
        );

        final futures = <Future<void>>[
          coordinator.start(),
          coordinator.stop(),
          coordinator.start(),
        ];
        await Future.wait(futures);

        final running = coordinator.state == SyncState.running;
        expect(coordinator.gossipEngineForTesting!.isRunning, equals(running));
        expect(
          coordinator.failureDetectorForTesting!.isRunning,
          equals(running),
        );
      },
    );
  });

  group('Coordinator pause/resume channel visibility', () {
    test('a channel created while paused is gossiped after resume()', () async {
      final bus = InMemoryMessageBus();
      final timePort = InMemoryTimePort();
      final coordinator = await createTestCoordinator(
        bus: bus,
        timePort: timePort,
        config: _fastNetworkConfig,
      );

      final peerId = NodeId('peer1');
      final peerPort = InMemoryMessagePort(peerId, bus);
      final codec = SyncMessageCodec();
      final digests = <DigestRequest>[];
      final sub = peerPort.incoming.listen((msg) {
        final decoded = codec.decode(msg.bytes);
        if (decoded is DigestRequest) digests.add(decoded);
      });

      await coordinator.start();
      await coordinator.addPeer(peerId);
      await coordinator.pause();

      // Created while paused: must still reach the engine on resume.
      final channelId = ChannelId('created-while-paused');
      final channel = await coordinator.createChannel(channelId);
      await channel.getOrCreateStream(StreamId('s1'));

      await coordinator.resume();

      // Let a gossip round fire (up to 3 attempts).
      for (var i = 0; i < 3; i++) {
        await timePort.advance(const Duration(milliseconds: 101));
        await pumpEventQueue();
      }

      expect(digests, isNotEmpty, reason: 'gossip rounds should have fired');
      expect(
        digests.last.digests.map((d) => d.channelId),
        contains(channelId),
        reason: 'channels created while paused must be gossiped after resume',
      );

      await sub.cancel();
      await peerPort.close();
    });
  });

  group('Coordinator dispose robustness', () {
    test('dispose() during an in-flight merge does not throw', () async {
      final coordinator = await createTestCoordinator(
        bus: InMemoryMessageBus(),
        timePort: InMemoryTimePort(),
        config: _fastNetworkConfig,
      );
      final channelId = ChannelId('ch1');
      final streamId = StreamId('s1');
      final channel = await coordinator.createChannel(channelId);
      await channel.getOrCreateStream(streamId);

      // Kick off the merge path (it suspends on materializer folding /
      // version vector reads), then dispose mid-flight.
      final engine = coordinator.gossipEngineForTesting!;
      final merge = engine.onEntriesMerged!.call(channelId, streamId, [
        LogEntry(
          author: NodeId('peer1'),
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([1]),
        ),
      ], false);
      // Dispose is the act under test — not builder-teardown cleanup.
      await coordinator.dispose();

      await expectLater(merge, completes);
    });

    test('dispose() closes materializer state streams', () async {
      final coordinator = await createTestCoordinator(
        bus: InMemoryMessageBus(),
        timePort: InMemoryTimePort(),
        config: _fastNetworkConfig,
      );
      final channel = await coordinator.createChannel(ChannelId('ch1'));
      final stream = await channel.getOrCreateStream(StreamId('s1'));
      await stream.registerMaterializer(_CountMaterializer());

      var done = false;
      final sub = stream.stateStream<int>()!.listen(
        (_) {},
        onDone: () => done = true,
      );
      addTearDown(sub.cancel);

      // Dispose is the act under test — not builder-teardown cleanup.
      await coordinator.dispose();
      await pumpUntil(
        () => done,
        describe:
            'the materializer state stream calling onDone after dispose '
            '(listeners must not leak forever)',
      );
    });
  });

  group('Coordinator monitoring under concurrent mutation', () {
    test('getResourceUsage tolerates channels created mid-iteration', () async {
      final coordinator = await createTestCoordinator(
        bus: InMemoryMessageBus(),
        timePort: InMemoryTimePort(),
        config: _fastNetworkConfig,
      );
      final channel = await coordinator.createChannel(ChannelId('ch1'));
      await channel.getOrCreateStream(StreamId('s1'));
      final channel2 = await coordinator.createChannel(ChannelId('ch2'));
      await channel2.getOrCreateStream(StreamId('s2'));

      // Interleave a channel creation with the (await-laden) iteration.
      final usageFuture = coordinator.getResourceUsage();
      await coordinator.createChannel(ChannelId('ch3'));

      await expectLater(
        usageFuture,
        completes,
        reason:
            'iterating live map keys across awaits throws '
            'ConcurrentModificationError',
      );
    });

    test('channelsForPeer tolerates channels created mid-iteration', () async {
      final coordinator = await createTestCoordinator(
        bus: InMemoryMessageBus(),
        timePort: InMemoryTimePort(),
        config: _fastNetworkConfig,
      );
      await coordinator.createChannel(ChannelId('ch1'));
      await coordinator.createChannel(ChannelId('ch2'));

      final future = coordinator.channelsForPeer(NodeId('peer1'));
      await coordinator.createChannel(ChannelId('ch3'));

      await expectLater(future, completes);
    });
  });

  group('Engine message subscriptions survive stream errors', () {
    test('a transport stream error is emitted, not silently fatal', () async {
      final controller = StreamController<IncomingMessage>.broadcast();
      final port = _ErroringMessagePort(controller);
      final errors = <Object>[];

      // Kept hand-rolled: needs a MessagePort whose incoming stream can be
      // made to emit an error on demand, which the builder's `bus`
      // parameter (backed by InMemoryMessageBus) cannot express.
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: port,
        timePort: InMemoryTimePort(),
      );
      addTearDown(coordinator.dispose);
      coordinator.errors.listen(errors.add);
      await coordinator.start();

      controller.addError(StateError('transport blew up'));
      await pumpUntil(
        () => errors.isNotEmpty,
        describe: 'the transport stream error reaching coordinator.errors',
      );

      // GossipEngine and FailureDetector both listen on this same broadcast
      // stream, so this one error deterministically reaches errors twice —
      // but the two PeerSyncErrors are byte-identical (same peer/type/
      // message/cause) with nothing to attribute either to its listener, so
      // only the shape is pinned below rather than a count.
      expect(
        errors.first,
        isA<PeerSyncError>().having(
          (e) => e.type,
          'type',
          SyncErrorType.protocolError,
        ),
        reason:
            'a transport error must surface via the errors stream as a '
            'protocol-level error, not kill SWIM/gossip listening as an '
            'unhandled zone error',
      );

      await controller.close();
    });
  });
}

class _ErroringMessagePort extends MessagePort {
  final StreamController<IncomingMessage> controller;
  _ErroringMessagePort(this.controller);

  @override
  Stream<IncomingMessage> get incoming => controller.stream;

  @override
  Future<void> send(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {}

  @override
  Future<void> close() async {}
}
