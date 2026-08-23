import 'dart:typed_data';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
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

  group('GossipEngine reactive push-on-write (G1)', () {
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
}
