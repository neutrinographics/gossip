import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/interfaces/state_materializer.dart';
import 'package:gossip/src/facade/coordinator.dart';
import 'package:gossip/src/facade/coordinator_config.dart';
import 'package:gossip/src/facade/sync_state.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/shared/domain/interfaces/message_port.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_channel_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_peer_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

class _CountMaterializer extends StateMaterializer<int> {
  @override
  (int, String?) initial({required bool isReset}) => (0, null);

  @override
  int fold(int state, LogEntry entry) => state + 1;
}

void main() {
  final localNode = NodeId('local');

  Future<Coordinator> createCoordinator({
    InMemoryMessageBus? bus,
    InMemoryTimePort? timePort,
  }) {
    return Coordinator.create(
      localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
      channelRepository: InMemoryChannelRepository(),
      peerRepository: InMemoryPeerRepository(),
      entryRepository: InMemoryEntryRepository(),
      messagePort: InMemoryMessagePort(localNode, bus ?? InMemoryMessageBus()),
      timerPort: timePort ?? InMemoryTimePort(),
      config: const CoordinatorConfig(
        gossipInterval: Duration(milliseconds: 100),
        probeInterval: Duration(milliseconds: 100),
        pingTimeout: Duration(milliseconds: 50),
        startupGracePeriod: Duration.zero,
      ),
    );
  }

  group('Coordinator start/stop interleaving', () {
    test('stop() during an in-flight start() wins — engines never run',
        () async {
      final coordinator = await createCoordinator();

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

      await coordinator.dispose();
    });

    test('state always matches engine liveness after start/stop churn',
        () async {
      final coordinator = await createCoordinator();

      final futures = <Future<void>>[
        coordinator.start(),
        coordinator.stop(),
        coordinator.start(),
      ];
      await Future.wait(futures);

      final running = coordinator.state == SyncState.running;
      expect(coordinator.gossipEngineForTesting!.isRunning, equals(running));
      expect(coordinator.failureDetectorForTesting!.isRunning, equals(running));

      await coordinator.dispose();
    });
  });

  group('Coordinator pause/resume channel visibility', () {
    test('a channel created while paused is gossiped after resume()',
        () async {
      final bus = InMemoryMessageBus();
      final timePort = InMemoryTimePort();
      final coordinator = await createCoordinator(bus: bus, timePort: timePort);

      final peerId = NodeId('peer1');
      final peerPort = InMemoryMessagePort(peerId, bus);
      final codec = ProtocolCodec();
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

      // Let a gossip round fire.
      for (var i = 0; i < 3; i++) {
        await timePort.advance(const Duration(milliseconds: 101));
        await Future.delayed(Duration.zero);
      }

      expect(digests, isNotEmpty, reason: 'gossip rounds should have fired');
      expect(
        digests.last.digests.map((d) => d.channelId),
        contains(channelId),
        reason: 'channels created while paused must be gossiped after resume',
      );

      await sub.cancel();
      await peerPort.close();
      await coordinator.dispose();
    });
  });

  group('Coordinator dispose robustness', () {
    test('dispose() during an in-flight merge does not throw', () async {
      final coordinator = await createCoordinator();
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
      await coordinator.dispose();

      await expectLater(merge, completes);
    });

    test('dispose() closes materializer state streams', () async {
      final coordinator = await createCoordinator();
      final channel = await coordinator.createChannel(ChannelId('ch1'));
      final stream = await channel.getOrCreateStream(StreamId('s1'));
      await stream.registerMaterializer(_CountMaterializer());

      var done = false;
      final sub = stream.stateStream<int>()!.listen(
        (_) {},
        onDone: () => done = true,
      );

      await coordinator.dispose();
      await Future.delayed(Duration.zero);

      expect(
        done,
        isTrue,
        reason: 'listeners must get onDone instead of leaking forever',
      );
      await sub.cancel();
    });
  });

  group('Coordinator monitoring under concurrent mutation', () {
    test('getResourceUsage tolerates channels created mid-iteration',
        () async {
      final coordinator = await createCoordinator();
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
        reason: 'iterating live map keys across awaits throws '
            'ConcurrentModificationError',
      );

      await coordinator.dispose();
    });

    test('channelsForPeer tolerates channels created mid-iteration',
        () async {
      final coordinator = await createCoordinator();
      await coordinator.createChannel(ChannelId('ch1'));
      await coordinator.createChannel(ChannelId('ch2'));

      final future = coordinator.channelsForPeer(NodeId('peer1'));
      await coordinator.createChannel(ChannelId('ch3'));

      await expectLater(future, completes);

      await coordinator.dispose();
    });
  });

  group('Engine message subscriptions survive stream errors', () {
    test('a transport stream error is emitted, not silently fatal',
        () async {
      final controller = StreamController<IncomingMessage>.broadcast();
      final port = _ErroringMessagePort(controller);
      final errors = <Object>[];

      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: port,
        timerPort: InMemoryTimePort(),
      );
      coordinator.errors.listen(errors.add);
      await coordinator.start();

      controller.addError(StateError('transport blew up'));
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(
        errors,
        isNotEmpty,
        reason: 'a transport error must surface via the errors stream, not '
            'kill SWIM/gossip listening as an unhandled zone error',
      );

      await coordinator.dispose();
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
  Future<void> send(NodeId destination, Uint8List bytes,
      {MessagePriority priority = MessagePriority.normal}) async {}

  @override
  Future<void> close() async {}
}
