import 'dart:typed_data';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/aggregates/stalled_range_registry.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:gossip/src/sync/domain/messages/digest_response.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');
  final authorA = NodeId('author-a');
  final authorB = NodeId('author-b');

  LogEntry entryOf(NodeId author, int seq, int tsMs) => LogEntry(
    author: author,
    sequence: seq,
    timestamp: Hlc(tsMs, 0),
    payload: Uint8List.fromList([seq % 256]),
  );

  DigestResponse digestOf(NodeId sender, Map<NodeId, int> versions) =>
      DigestResponse(
        sender: sender,
        digests: [
          ChannelDigest(
            channelId: channelId,
            streams: [
              StreamDigest(streamId: streamId, version: VersionVector(versions)),
            ],
          ),
        ],
      );

  late GossipEngineTestHarness h;
  late StalledRangeRegistry stalled;
  late GossipTestPeer peer;
  late GossipTestPeer otherPeer;

  setUp(() async {
    stalled = StalledRangeRegistry();
    h = GossipEngineTestHarness(stalledRanges: stalled);
    h.createChannel('ch1', streamIds: ['s1']);
    peer = h.addPeer('peer1');
    otherPeer = h.addPeer('peer2');
    for (var i = 1; i <= 5; i++) {
      await h.entryRepository.append(channelId, streamId, entryOf(authorA, i, 1000 + i));
    }
  });

  tearDown(() => h.dispose());

  test('a recorded gap shapes the next request to the peer', () async {
    // The digest advertises a stalled surplus for authorA AND a live
    // surplus for authorB — the live surplus is what makes a request go
    // out at all (a lone stalled surplus is dominance-suppressed, which
    // the next test pins).
    stalled.recordGap(
      peer.id,
      channelId,
      streamId,
      authorA,
      expectedNext: 6,
      advertisedMax: 208,
      nowMs: h.timePort.nowMs,
    );

    final requests = await h.engine.handleDigestResponse(
      digestOf(peer.id, {authorA: 208, authorB: 3}),
    );

    expect(requests, hasLength(1));
    expect(
      requests.single.since[authorA],
      208,
      reason: 'the digest ceiling equals advertisedMax here; the shaped '
          'since must silence the author',
    );
    expect(
      requests.single.since[authorB],
      0,
      reason: 'the live author is requested from the start',
    );
  });

  test(
    'when the stalled surplus is the only surplus, no request is sent '
    'and the pull flag is released',
    () async {
      stalled.recordGap(
        peer.id,
        channelId,
        streamId,
        authorA,
        expectedNext: 6,
        advertisedMax: 208,
        nowMs: h.timePort.nowMs,
      );

      final requests = await h.engine.handleDigestResponse(
        digestOf(peer.id, {authorA: 208}),
      );

      expect(
        requests,
        isEmpty,
        reason: 'shaped vector dominates the digest — nothing to ask',
      );
      expect(
        h.engine.outstandingPullCount,
        0,
        reason: 'the dedup flag must be released, not leaked',
      );
    },
  );

  test('stop() clears suppressions', () async {
    h.engine.start();
    stalled.recordGap(
      peer.id,
      channelId,
      streamId,
      authorA,
      expectedNext: 6,
      advertisedMax: 208,
      nowMs: h.timePort.nowMs,
    );
    h.engine.stop();

    final requests = await h.engine.handleDigestResponse(
      digestOf(peer.id, {authorA: 208}),
    );
    expect(
      requests.single.since[authorA],
      5,
      reason: 'a restart is a fresh diagnosis window — unshaped',
    );
  });

  test('peer removal clears that peer only', () async {
    stalled.recordGap(
      peer.id,
      channelId,
      streamId,
      authorA,
      expectedNext: 6,
      advertisedMax: 208,
      nowMs: h.timePort.nowMs,
    );
    stalled.recordGap(
      otherPeer.id,
      channelId,
      streamId,
      authorA,
      expectedNext: 6,
      advertisedMax: 208,
      nowMs: h.timePort.nowMs,
    );

    h.engine.clearPendingRequestsForPeer(peer.id);

    final cleared = await h.engine.handleDigestResponse(
      digestOf(peer.id, {authorA: 208}),
    );
    expect(
      cleared.single.since[authorA],
      5,
      reason: 'cleared peer is unshaped',
    );

    final kept = await h.engine.handleDigestResponse(
      digestOf(otherPeer.id, {authorA: 208}),
    );
    expect(
      kept,
      isEmpty,
      reason: 'other peer keeps its suppression — dominance-quiet',
    );
  });

  group('end-to-end recording (merger seam)', () {
    Future<void> solicit() => h.engine.handleDigestResponse(
      digestOf(peer.id, {authorA: 208}),
    );

    test(
      'after one solicited gapped response, the stalled surplus is '
      'suppressed and dominance-quiet',
      () async {
        await solicit(); // arms the pull; the response below is solicited
        await h.engine.handleDeltaResponse(
          DeltaResponse(
            sender: peer.id,
            channelId: channelId,
            streamId: streamId,
            entries: [entryOf(authorA, 149, 2149), entryOf(authorA, 208, 2208)],
          ),
        );

        final requests = await h.engine.handleDigestResponse(
          digestOf(peer.id, {authorA: 208}),
        );
        expect(
          requests,
          isEmpty,
          reason: 'stalled surplus was the only surplus — suppressed and '
              'dominance-quiet',
        );
      },
    );
  });
}
