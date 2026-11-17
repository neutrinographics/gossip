// Send side of digest scoping: a request digests the channels the peer has
// shown it holds and announces the rest under the announce budget.
//
// Translates the send-side cases of the Kotlin twin's
// src/test/kotlin/com/neutrinographics/gossip/sync/application/GossipEngineTest.kt
// ("a request to a peer that has shown nothing announces every channel and
// digests none", "once a peer has shown a channel, ...", "a round's request is
// scoped the same way as syncWithPeer's", "a hub over the announce budget
// names every channel ...", "an announce budget of zero sends digests only",
// and the unannounceable warning).
//
// The receive-side cases translate the same file's holdings, drop-at-debug,
// answering and forgetting cases.
import 'dart:typed_data';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/messages/delta_request.dart';
import 'package:gossip/src/sync/domain/messages/digest_response.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

void main() {
  final channel1 = ChannelId('channel-1');
  final channel2 = ChannelId('channel-2');

  Future<List<DigestRequest>> requestsAfter(
    GossipEngineTestHarness h,
    GossipTestPeer peer,
    Future<void> Function() act,
  ) async {
    final (messages, sub) = h.captureMessages(peer);
    await act();
    await h.flush(3);
    await sub.cancel();
    return messages.whereType<DigestRequest>().toList();
  }

  group('digest request scoping', () {
    test('a request to a peer that has shown nothing announces every channel '
        'and digests none', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      h.createChannel('channel-1', streamIds: ['s']);
      h.createChannel('channel-2', streamIds: ['s']);
      h.startListening();
      h.engine.start();

      final requests = await requestsAfter(
        h,
        peer,
        () => h.engine.syncWithPeer(peer.id),
      );

      expect(requests.single.digests, isEmpty);
      expect(requests.single.announced.toSet(), equals({channel1, channel2}));
      h.engine.stop();
      h.stopListening();
    });

    test('a round\'s request is scoped the same way as syncWithPeer\'s '
        '(nothing shown: announced, not digested)', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      h.createChannel('channel-1', streamIds: ['s']);
      h.createChannel('channel-2', streamIds: ['s']);
      h.startListening();
      h.engine.start();

      final requests = await requestsAfter(
        h,
        peer,
        () => h.engine.performGossipRound(),
      );

      expect(requests.single.digests, isEmpty);
      expect(requests.single.announced.toSet(), equals({channel1, channel2}));
      h.engine.stop();
      h.stopListening();
    });

    test('once a peer has shown a channel, the next request digests it and '
        'announces the rest', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      h.createChannel('channel-1', streamIds: ['s']);
      h.createChannel('channel-2', streamIds: ['s']);
      h.startListening();
      h.engine.start();
      await h.peerHasShown(peer, [channel1]);

      final requests = await requestsAfter(
        h,
        peer,
        () => h.engine.syncWithPeer(peer.id),
      );

      expect(requests.single.digests.map((d) => d.channelId), [channel1]);
      expect(requests.single.announced, [channel2]);
      h.engine.stop();
      h.stopListening();
    });

    test('a round\'s request digests the shown channel and announces the '
        'rest, as syncWithPeer\'s does', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      h.createChannel('channel-1', streamIds: ['s']);
      h.createChannel('channel-2', streamIds: ['s']);
      h.startListening();
      h.engine.start();
      await h.peerHasShown(peer, [channel1]);

      final requests = await requestsAfter(
        h,
        peer,
        () => h.engine.performGossipRound(),
      );

      expect(requests.single.digests.map((d) => d.channelId), [channel1]);
      expect(requests.single.announced, [channel2]);
      h.engine.stop();
      h.stopListening();
    });

    test('a hub over the announce budget names every channel to a peer across '
        'successive requests', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
        announceBudgetBytes: 1024,
      );
      final peer = h.addPeer('peer1');
      final ids = [
        for (var i = 0; i < 40; i++)
          'hub-channel-${i.toString().padLeft(24, '0')}',
      ];
      for (final id in ids) {
        h.createChannel(id, streamIds: ['s']);
      }
      h.startListening();
      h.engine.start();

      final requests = await requestsAfter(h, peer, () async {
        for (var i = 0; i < 4; i++) {
          await h.engine.syncWithPeer(peer.id);
        }
      });

      expect(requests, hasLength(4));
      final base = h.codec
          .encode(DigestRequest(sender: h.localNode, digests: const []))
          .length;
      for (final r in requests) {
        final cost =
            h.codec
                .encode(
                  DigestRequest(
                    sender: h.localNode,
                    digests: const [],
                    announced: r.announced,
                  ),
                )
                .length -
            base;
        expect(
          cost,
          lessThanOrEqualTo(1024),
          reason: 'announced encodes $cost',
        );
      }
      expect(
        requests.take(3).expand((r) => r.announced).map((c) => c.value).toSet(),
        equals(ids.toSet()),
      );
      final sequence = requests.expand((r) => r.announced).toList();
      expect(
        sequence.take(40).toSet(),
        hasLength(40),
        reason: 'an id repeated before every id had appeared',
      );
      h.engine.stop();
      h.stopListening();
    });

    test('an announce budget of zero sends digests only', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
        announceBudgetBytes: 0,
      );
      final peer = h.addPeer('peer1');
      h.createChannel('channel-1', streamIds: ['s']);
      h.startListening();
      h.engine.start();

      final requests = await requestsAfter(
        h,
        peer,
        () => h.engine.syncWithPeer(peer.id),
      );

      expect(requests.single.digests, isEmpty);
      expect(requests.single.announced, isEmpty);
      h.engine.stop();
      h.stopListening();
    });

    test('an announce budget of zero still digests a shown channel', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
        announceBudgetBytes: 0,
      );
      final peer = h.addPeer('peer1');
      h.createChannel('channel-1', streamIds: ['s']);
      h.startListening();
      h.engine.start();
      await h.peerHasShown(peer, [channel1]);

      final requests = await requestsAfter(
        h,
        peer,
        () => h.engine.syncWithPeer(peer.id),
      );

      expect(requests.single.digests.map((d) => d.channelId), [channel1]);
      expect(requests.single.announced, isEmpty);
      h.engine.stop();
      h.stopListening();
    });

    test('a channel whose name alone exceeds the announce budget is warned '
        'about, never dropped silently', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
        announceBudgetBytes: 50,
      );
      final peer = h.addPeer('peer1');
      final long = ChannelId('c' * 60);
      h.createChannel(long.value, streamIds: ['s']);
      h.createChannel('ok', streamIds: ['s']);
      h.startListening();
      h.engine.start();

      final requests = await requestsAfter(
        h,
        peer,
        () => h.engine.syncWithPeer(peer.id),
      );

      expect(requests.single.announced, isNot(contains(long)));
      expect(
        h.logs,
        anyElement(
          allOf(
            contains('warning'),
            contains('cannot announce ${long.value}'),
            contains('announceBudgetBytes=50'),
          ),
        ),
      );
      h.engine.stop();
      h.stopListening();
    });
  });

  group('digest request receive side', () {
    Future<void> seedLocal(GossipEngineTestHarness h, ChannelId c) =>
        h.appendLocalEntry(c, StreamId('s'), sequence: 1);

    ChannelDigest digestOf(ChannelId c, {Map<NodeId, int>? version}) =>
        ChannelDigest(
          channelId: c,
          streams: [
            StreamDigest(
              streamId: StreamId('s'),
              version: VersionVector(version ?? const {}),
            ),
          ],
        );

    Future<List<dynamic>> deliver(
      GossipEngineTestHarness h,
      GossipTestPeer peer,
      DigestRequest request,
    ) async {
      final (messages, sub) = h.captureMessages(peer);
      await peer.port.send(h.localNode, h.codec.encode(request));
      await h.flush(3);
      await sub.cancel();
      return messages;
    }

    test('a request\'s names teach the sender\'s holdings before anything '
        'else', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      h.createChannel('channel-1', streamIds: ['s']);
      h.createChannel('channel-2', streamIds: ['s']);
      h.startListening();
      h.engine.start();

      await deliver(
        h,
        peer,
        DigestRequest(
          sender: peer.id,
          digests: const [],
          announced: [channel1, ChannelId('not-ours')],
        ),
      );
      final requests = await requestsAfter(
        h,
        peer,
        () => h.engine.syncWithPeer(peer.id),
      );

      expect(requests.single.digests.map((d) => d.channelId), [channel1]);
      expect(requests.single.announced, [channel2]);
      h.engine.stop();
      h.stopListening();
    });

    test('a response\'s names teach holdings too', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      h.createChannel('channel-1', streamIds: ['s']);
      h.startListening();
      h.engine.start();
      await h.peerHasShown(peer, [channel1]);

      final requests = await requestsAfter(
        h,
        peer,
        () => h.engine.syncWithPeer(peer.id),
      );

      expect(requests.single.digests.map((d) => d.channelId), [channel1]);
      h.engine.stop();
      h.stopListening();
    });

    test(
      'an announced channel we hold is answered with our whole digest',
      () async {
        final h = GossipEngineTestHarness(
          gossipInterval: const Duration(seconds: 100),
        );
        final peer = h.addPeer('peer1');
        h.createChannel('channel-1', streamIds: ['s']);
        await seedLocal(h, channel1);
        h.startListening();

        final messages = await deliver(
          h,
          peer,
          DigestRequest(
            sender: peer.id,
            digests: const [],
            announced: [channel1],
          ),
        );

        final response = messages.whereType<DigestResponse>().single;
        expect(response.digests.single.channelId, channel1);
        expect(response.digests.single.streams.single.streamId, StreamId('s'));
        h.stopListening();
      },
    );

    test('an announced channel we hold with no streams is still answered, '
        'empty, when the answer has to be fitted', () async {
      final h = GossipEngineTestHarness(
        maxMessageBytes: 400,
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      final empty = ChannelId('empty-channel');
      h.createChannel(empty.value);
      final fat = [for (var i = 0; i < 6; i++) ChannelId('fat-channel-$i')];
      for (final c in fat) {
        h.createChannel(c.value, streamIds: ['s']);
        for (var a = 0; a < 5; a++) {
          await h.appendEntry(
            c,
            StreamId('s'),
            LogEntry(
              author: NodeId('author-$a'),
              sequence: 1,
              timestamp: Hlc(1000 + a, 0),
              payload: Uint8List.fromList([a]),
            ),
          );
        }
      }
      h.startListening();

      final messages = await deliver(
        h,
        peer,
        DigestRequest(
          sender: peer.id,
          digests: const [],
          announced: [empty, ...fat],
        ),
      );

      final response = messages.whereType<DigestResponse>().single;
      final answered = {for (final d in response.digests) d.channelId: d};
      expect(answered[empty]?.streams, isEmpty);
      expect(answered.containsKey(empty), isTrue);
      h.stopListening();
    });

    test('a digested channel is answered scoped to the named streams and '
        'dominance-filtered', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      h.createChannel(
        'channel-1',
        streamIds: ['ahead', 'dominated', 'unnamed'],
      );
      for (final s in ['ahead', 'dominated', 'unnamed']) {
        await h.appendLocalEntry(channel1, StreamId(s), sequence: 1);
      }
      h.startListening();

      final messages = await deliver(
        h,
        peer,
        DigestRequest(
          sender: peer.id,
          digests: [
            ChannelDigest(
              channelId: channel1,
              streams: [
                StreamDigest(
                  streamId: StreamId('ahead'),
                  version: VersionVector.empty,
                ),
                StreamDigest(
                  streamId: StreamId('dominated'),
                  version: VersionVector({h.localNode: 1}),
                ),
              ],
            ),
          ],
        ),
      );

      final response = messages.whereType<DigestResponse>().single;
      expect(response.digests.single.streams.map((s) => s.streamId.value), [
        'ahead',
      ]);
      h.stopListening();
    });

    test('a named channel we do not hold is dropped at debug, appears nowhere '
        'in the response, and is not an error', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      h.createChannel('channel-1', streamIds: ['s']);
      await seedLocal(h, channel1);
      h.startListening();
      final stranger = ChannelId('stranger');

      final messages = await deliver(
        h,
        peer,
        DigestRequest(
          sender: peer.id,
          digests: [digestOf(stranger)],
          announced: [channel1],
        ),
      );

      final response = messages.whereType<DigestResponse>().single;
      expect(response.digests.map((d) => d.channelId), [channel1]);
      expect(h.errors, isEmpty);
      expect(
        h.logs,
        anyElement(
          allOf(
            startsWith('LogLevel.debug:'),
            contains('dropping stranger named by peer1'),
            contains('not a channel of ours'),
          ),
        ),
      );
      h.stopListening();
    });

    test('the reciprocal pull is planned from the request\'s held digests '
        'only: an announcement pulls nothing', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      h.createChannel('channel-1', streamIds: ['s']);
      h.createChannel('channel-2', streamIds: ['s']);
      h.startListening();
      h.engine.start();

      final announcedOnly = await deliver(
        h,
        peer,
        DigestRequest(
          sender: peer.id,
          digests: const [],
          announced: [channel1],
        ),
      );
      expect(announcedOnly.whereType<DeltaRequest>(), isEmpty);

      final digested = await deliver(
        h,
        peer,
        DigestRequest(
          sender: peer.id,
          digests: [
            digestOf(channel2, version: {peer.id: 3}),
            digestOf(ChannelId('stranger'), version: {peer.id: 3}),
          ],
        ),
      );
      expect(digested.whereType<DeltaRequest>().map((r) => r.channelId), [
        channel2,
      ]);
      expect(h.errors, isEmpty);
      h.engine.stop();
      h.stopListening();
    });

    test('a response naming a channel we do not hold is dropped at debug '
        'while the held ones are still pulled', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      h.createChannel('channel-1', streamIds: ['s']);
      h.startListening();
      h.engine.start();

      final (messages, sub) = h.captureMessages(peer);
      await peer.port.send(
        h.localNode,
        h.codec.encode(
          DigestResponse(
            sender: peer.id,
            digests: [
              digestOf(ChannelId('stranger'), version: {peer.id: 2}),
              digestOf(channel1, version: {peer.id: 2}),
            ],
          ),
        ),
      );
      await h.flush(3);
      await sub.cancel();

      expect(messages.whereType<DeltaRequest>().map((r) => r.channelId), [
        channel1,
      ]);
      expect(h.errors, isEmpty);
      expect(h.logs, anyElement(contains('dropping stranger named by peer1')));
      h.engine.stop();
      h.stopListening();
    });

    test('an old-shape request (every channel digested, none announced) '
        'fills holdings with all of them', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      h.createChannel('channel-1', streamIds: ['s']);
      h.createChannel('channel-2', streamIds: ['s']);
      h.startListening();
      h.engine.start();
      await deliver(
        h,
        peer,
        DigestRequest(
          sender: peer.id,
          digests: [digestOf(channel1), digestOf(channel2)],
        ),
      );

      final requests = await requestsAfter(
        h,
        peer,
        () => h.engine.syncWithPeer(peer.id),
      );

      expect(requests.single.digests.map((d) => d.channelId).toSet(), {
        channel1,
        channel2,
      });
      expect(requests.single.announced, isEmpty);
      h.engine.stop();
      h.stopListening();
    });

    test('removing a peer forgets its holdings, so the next request announces '
        'again', () async {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
      );
      final peer = h.addPeer('peer1');
      h.createChannel('channel-1', streamIds: ['s']);
      h.startListening();
      h.engine.start();
      await h.peerHasShown(peer, [channel1]);

      h.engine.clearPendingRequestsForPeer(peer.id);
      final requests = await requestsAfter(
        h,
        peer,
        () => h.engine.syncWithPeer(peer.id),
      );

      expect(requests.single.digests, isEmpty);
      expect(requests.single.announced, [channel1]);
      h.engine.stop();
      h.stopListening();
    });

    Future<List<DigestRequest>> hubRequests(
      GossipEngineTestHarness h,
      GossipTestPeer peer,
      int count,
    ) => requestsAfter(h, peer, () async {
      for (var i = 0; i < count; i++) {
        await h.engine.syncWithPeer(peer.id);
      }
    });

    GossipEngineTestHarness hub() {
      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(seconds: 100),
        announceBudgetBytes: 1024,
      );
      for (var i = 0; i < 40; i++) {
        h.createChannel(
          'hub-channel-${i.toString().padLeft(24, '0')}',
          streamIds: ['s'],
        );
      }
      return h;
    }

    test('removing a peer forgets its rotation, so announcements start '
        'over', () async {
      final h = hub();
      final peer = h.addPeer('peer1');
      h.startListening();
      h.engine.start();

      final first = await hubRequests(h, peer, 2);
      h.engine.clearPendingRequestsForPeer(peer.id);
      final again = await hubRequests(h, peer, 1);

      expect(first[0].announced.first, isNot(first[1].announced.first));
      expect(again.single.announced.first, first[0].announced.first);
      h.engine.stop();
      h.stopListening();
    });

    test(
      'a stop forgets every peer\'s holdings and resets the rotation',
      () async {
        final h = hub();
        final peer = h.addPeer('peer1');
        h.startListening();
        h.engine.start();
        final shown = ChannelId('hub-channel-${'0'.padLeft(24, '0')}');
        await h.peerHasShown(peer, [shown]);
        final before = await hubRequests(h, peer, 2);
        expect(before.first.digests, isNotEmpty);

        h.engine.stop();
        h.engine.start();
        final after = await hubRequests(h, peer, 1);

        expect(after.single.digests, isEmpty);
        expect(after.single.announced.first, shown);
        h.engine.stop();
        h.stopListening();
      },
    );
  });
}
