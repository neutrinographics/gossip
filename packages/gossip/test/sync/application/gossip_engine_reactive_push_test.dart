import 'dart:typed_data';

import 'package:gossip/src/membership/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/log_level.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');

  // Long periodic interval so background rounds don't interfere with the
  // reactive-push assertions.
  GossipEngineTestHarness makeHarness() =>
      GossipEngineTestHarness(gossipInterval: const Duration(seconds: 100));

  LogEntry localEntry(GossipEngineTestHarness h, int seq) => LogEntry(
    author: h.localNode,
    sequence: seq,
    timestamp: Hlc(1000 + seq, 0),
    payload: Uint8List.fromList([seq]),
  );

  group('GossipEngine reactive push-on-write', () {
    test(
      'a local write is pushed to reachable peers after the debounce',
      () async {
        final h = makeHarness();
        final peer = h.addPeer('peer1');
        h.createChannel('ch1', streamIds: ['s1']);
        h.startListening();
        h.engine.start();
        final (messages, sub) = h.captureMessages(peer);

        h.engine.notifyLocalWrite(channelId, streamId, localEntry(h, 1));

        // Nothing pushed before the debounce window elapses.
        await h.flush();
        expect(messages.whereType<DeltaResponse>(), isEmpty);

        await h.timePort.advance(const Duration(milliseconds: 150));
        await h.flush(3);

        final pushes = messages.whereType<DeltaResponse>().toList();
        expect(pushes.length, equals(1));
        expect(pushes.single.channelId, equals(channelId));
        expect(pushes.single.streamId, equals(streamId));
        expect(pushes.single.entries.map((e) => e.sequence), equals([1]));

        await sub.cancel();
        h.engine.stop();
        h.stopListening();
      },
    );

    test('a burst of writes coalesces into a single push', () async {
      final h = makeHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);
      h.startListening();
      h.engine.start();
      final (messages, sub) = h.captureMessages(peer);

      h.engine.notifyLocalWrite(channelId, streamId, localEntry(h, 1));
      h.engine.notifyLocalWrite(channelId, streamId, localEntry(h, 2));
      h.engine.notifyLocalWrite(channelId, streamId, localEntry(h, 3));

      await h.timePort.advance(const Duration(milliseconds: 150));
      await h.flush(3);

      final pushes = messages.whereType<DeltaResponse>().toList();
      expect(pushes.length, equals(1), reason: 'debounce coalesces the burst');
      expect(pushes.single.entries.map((e) => e.sequence), equals([1, 2, 3]));

      await sub.cancel();
      h.engine.stop();
      h.stopListening();
    });

    test('a write while not running is not pushed (pause semantics)', () async {
      final h = makeHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);
      h.startListening();
      // engine NOT started (paused/listen-only)
      final (messages, sub) = h.captureMessages(peer);

      h.engine.notifyLocalWrite(channelId, streamId, localEntry(h, 1));
      await h.timePort.advance(const Duration(milliseconds: 150));
      await h.flush(3);

      expect(messages.whereType<DeltaResponse>(), isEmpty);

      await sub.cancel();
      h.stopListening();
    });

    test('a write with no reachable peers is a harmless no-op', () async {
      final h = makeHarness();
      h.createChannel('ch1', streamIds: ['s1']);
      h.startListening();
      h.engine.start();

      // No peers added.
      h.engine.notifyLocalWrite(channelId, streamId, localEntry(h, 1));
      await h.timePort.advance(const Duration(milliseconds: 150));
      await expectLater(h.flush(3), completes);

      h.engine.stop();
      h.stopListening();
    });
  });

  group('GossipEngine _flushPendingPushes silent-skip logging', () {
    // These two paths build the engine via [GossipEngineTestHarness.
    // buildEngine] directly (rather than the friendly instance factory)
    // because only buildEngine exposes onLog for observation.

    Future<void> flush([int count = 3]) async {
      for (var i = 0; i < count; i++) {
        await Future.delayed(Duration.zero);
      }
    }

    test('an oversized batch is skipped with a trace log naming '
        'channel/stream/encoded size', () async {
      final localNode = NodeId('local');
      final registry = PeerRegistry(localNode: localNode);
      registry.addPeer(NodeId('peer1'), occurredAt: DateTime.now());
      final timePort = InMemoryTimePort();
      final logs = <String>[];

      final engine = GossipEngineTestHarness.buildEngine(
        localNode: localNode,
        peerRegistry: registry,
        timePort: timePort,
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        onLog: (level, message, [error, stackTrace]) {
          if (level == LogLevel.trace) logs.add(message);
        },
        // Small enough that any non-empty push exceeds it.
        maxMessageBytes: 10,
      );
      GossipEngineTestHarness.registerChannel(engine, channelId, [streamId]);
      engine.start();

      engine.notifyLocalWrite(
        channelId,
        streamId,
        LogEntry(
          author: localNode,
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([1]),
        ),
      );
      await timePort.advance(const Duration(milliseconds: 150));
      await flush();

      expect(
        logs.any(
          (m) =>
              m.contains(channelId.value) &&
              m.contains(streamId.value) &&
              m.contains('10'),
        ),
        isTrue,
        reason:
            'the oversized-batch skip must name the channel, stream, '
            'and encoded size it silently dropped — otherwise a stuck '
            'stream is undiagnosable in the field',
      );

      engine.stop();
    });

    test('a drained batch with no reachable partners is logged, not '
        'silently discarded', () async {
      final localNode = NodeId('local');
      final registry = PeerRegistry(localNode: localNode);
      final timePort = InMemoryTimePort();
      final logs = <String>[];

      final engine = GossipEngineTestHarness.buildEngine(
        localNode: localNode,
        peerRegistry: registry,
        timePort: timePort,
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        onLog: (level, message, [error, stackTrace]) {
          if (level == LogLevel.trace) logs.add(message);
        },
      );
      GossipEngineTestHarness.registerChannel(engine, channelId, [streamId]);
      engine.start();

      // No peers added: the batch is drained by the pusher but has
      // nowhere reachable to go.
      engine.notifyLocalWrite(
        channelId,
        streamId,
        LogEntry(
          author: localNode,
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([1]),
        ),
      );
      await timePort.advance(const Duration(milliseconds: 150));
      await flush();

      expect(
        logs.any(
          (m) =>
              m.contains('reachable') &&
              (m.contains('anti-entropy') || m.contains('repository')),
        ),
        isTrue,
        reason:
            'a drained-but-undelivered batch must say so — entries stay '
            'repository-safe and anti-entropy re-delivers, but silently '
            'is undiagnosable',
      );

      engine.stop();
    });
  });
}
