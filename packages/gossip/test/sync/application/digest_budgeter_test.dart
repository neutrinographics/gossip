import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/application/digest_budgeter.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:test/test.dart';

/// Transplanted from gossip_engine_digest_budget_test.dart (CC5-1): these
/// pin the same byte-budgeting/rotation semantics `GossipEngine` relied on
/// before the extraction, now against [DigestBudgeter] directly.
void main() {
  final codec = SyncMessageCodec();
  final localNode = NodeId('local');
  final channelId = ChannelId('ch1');

  VersionVector authorsVersion(int count) =>
      VersionVector({for (var a = 0; a < count; a++) NodeId('author-$a'): 1});

  /// A stream digest whose encoded cost scales with [authorCount] (more
  /// authors in the version vector -> a larger digest).
  StreamDigest streamDigest(String id, int authorCount) => StreamDigest(
    streamId: StreamId(id),
    version: authorsVersion(authorCount),
  );

  /// The same conservative per-item cost [DigestBudgeter] itself budgets:
  /// the stream digest's encoded size plus a full channel envelope. Used
  /// only to size test fixtures precisely (never asserted against
  /// directly) so thresholds aren't hand-tuned magic numbers.
  int itemCost(StreamDigest digest) =>
      codec.encodedStreamDigestSize(digest) + channelId.value.length + 40;

  int baseSize() =>
      codec.encode(DigestRequest(sender: localNode, digests: const [])).length;

  List<String> streamIdsOf(List<ChannelDigest> digests) => [
    for (final cd in digests)
      for (final sd in cd.streams) sd.streamId.value,
  ];

  group('DigestBudgeter.fitRequest full-fit passthrough', () {
    test('a digest set that fits the budget passes through unchanged', () {
      final budgeter = DigestBudgeter(
        codec: codec,
        localNode: localNode,
        maxMessageBytes: 30 * 1024,
      );
      final all = [
        ChannelDigest(
          channelId: channelId,
          streams: [streamDigest('s0', 1), streamDigest('s1', 2)],
        ),
      ];

      final (digests, oversized) = budgeter.fitRequest(all);

      expect(digests, equals(all));
      expect(oversized, isEmpty);
    });
  });

  group('DigestBudgeter.fitRequest over-budget window selection', () {
    test('an over-budget request selects a rotated window that wraps past '
        'the end of the flattened stream list', () {
      // 5 streams, identical cost each (single-author version vectors of
      // the same shape), so the window size is deterministic.
      final streams = [for (var i = 0; i < 5; i++) streamDigest('s$i', 3)];
      final all = [ChannelDigest(channelId: channelId, streams: streams)];

      // Choose a budget that (a) cannot fit the full 5-stream digest, so
      // pagination kicks in, and (b) fits enough items per window that two
      // consecutive windows overlap past the end of the list — i.e. the
      // second window necessarily wraps back to index 0.
      final cost = itemCost(streams.first);
      final windowSize = 3;
      final maxMessageBytes = baseSize() + cost * windowSize;
      // Sanity: the full digest must not fit at this budget, or this test
      // would exercise the fast passthrough path instead of pagination.
      final fullEncoded = codec
          .encode(DigestRequest(sender: localNode, digests: all))
          .length;
      expect(
        fullEncoded,
        greaterThan(maxMessageBytes),
        reason:
            'fixture must actually be over budget for this test to '
            'exercise pagination',
      );

      final budgeter = DigestBudgeter(
        codec: codec,
        localNode: localNode,
        maxMessageBytes: maxMessageBytes,
      );

      final (first, firstOversized) = budgeter.fitRequest(all);
      final firstIds = streamIdsOf(first);
      expect(firstOversized, isEmpty);
      expect(firstIds, equals(['s0', 's1', 's2']));

      final (second, secondOversized) = budgeter.fitRequest(all);
      final secondIds = streamIdsOf(second);
      expect(secondOversized, isEmpty);
      // Starting right after the first window (index 3), wrapping modulo
      // the 5-item flattened list: 3, 4, 0.
      expect(
        secondIds,
        equals(['s3', 's4', 's0']),
        reason:
            'the rotation cursor must wrap past the end of the '
            'flattened list back to the start, or the streams before the '
            'wrap point would never be re-advertised',
      );
    });
  });

  group('DigestBudgeter cursor independence (OBS-3 regression)', () {
    test('a fitted request does not advance the response cursor, and a '
        'fitted response does not advance the request cursor', () {
      final streams = [for (var i = 0; i < 5; i++) streamDigest('s$i', 3)];
      final all = [ChannelDigest(channelId: channelId, streams: streams)];
      final flat = [for (final s in streams) (channel: channelId, digest: s)];

      final cost = itemCost(streams.first);
      final maxMessageBytes = baseSize() + cost * 3;

      final budgeter = DigestBudgeter(
        codec: codec,
        localNode: localNode,
        maxMessageBytes: maxMessageBytes,
      );

      // Advance the REQUEST cursor to index 3.
      final (req1, _) = budgeter.fitRequest(all);
      expect(streamIdsOf(req1), equals(['s0', 's1', 's2']));

      // A RESPONSE fit must start from its own untouched cursor (index 0),
      // not from wherever the request cursor landed.
      final (resp1, _) = budgeter.fitResponse(flat);
      expect(
        streamIdsOf(resp1),
        equals(['s0', 's1', 's2']),
        reason:
            'the response cursor must be independent of the request '
            'cursor — it has never been fitted before, so it must start '
            'at index 0 regardless of the request cursor already being at '
            'index 3',
      );

      // If the response fit above had incorrectly advanced (or shared)
      // the request cursor, this next request would repeat req1 (index 0)
      // instead of continuing the rotation from index 3.
      final (req2, _) = budgeter.fitRequest(all);
      expect(
        streamIdsOf(req2),
        equals(['s3', 's4', 's0']),
        reason:
            'a response fit must not advance the request cursor '
            '(OBS-3 regression)',
      );

      // Symmetric check: a request fit (req2 above) must not have touched
      // the response cursor either — the next response fit must continue
      // from where resp1 left off (index 3), not restart at index 0.
      final (resp2, _) = budgeter.fitResponse(flat);
      expect(
        streamIdsOf(resp2),
        equals(['s3', 's4', 's0']),
        reason:
            'a request fit must not advance the response cursor '
            '(OBS-3 regression)',
      );
    });
  });

  group('DigestBudgeter alone-over-budget stream handling', () {
    test('a stream whose digest alone exceeds the budget is skipped, '
        'reported as a diagnostic, and the cursor advances past it', () {
      final big = streamDigest('big', 60); // huge VV, alone exceeds budget
      final small1 = streamDigest('small1', 1);
      final small2 = streamDigest('small2', 1);
      final all = [
        ChannelDigest(channelId: channelId, streams: [big, small1, small2]),
      ];

      // Budget: room for the envelope plus exactly one small item — never
      // enough for `big` alone.
      final maxMessageBytes = baseSize() + itemCost(small1);
      expect(
        baseSize() + itemCost(big),
        greaterThan(maxMessageBytes),
        reason: 'fixture must make `big` alone-over-budget',
      );

      final budgeter = DigestBudgeter(
        codec: codec,
        localNode: localNode,
        maxMessageBytes: maxMessageBytes,
      );

      final (firstDigests, firstOversized) = budgeter.fitRequest(all);
      expect(
        streamIdsOf(firstDigests),
        equals(['small1']),
        reason:
            'the deliverable stream is still advertised even though '
            'the oversized stream was encountered first in the flattened '
            'list — the loop must continue past it within the same call',
      );
      expect(firstOversized, hasLength(1));
      expect(firstOversized.single.channel, equals(channelId));
      expect(firstOversized.single.streamId, equals(StreamId('big')));
      expect(
        firstOversized.single.cost,
        equals(itemCost(big)),
        reason:
            'the diagnostic must carry the actual computed cost, not '
            'just a flag',
      );

      // A second call proves the persistent rotation cursor advanced PAST
      // the oversized stream's own index rather than getting stuck there:
      // it now advertises the OTHER small stream, not the same one again.
      final (secondDigests, secondOversized) = budgeter.fitRequest(all);
      expect(
        streamIdsOf(secondDigests),
        equals(['small2']),
        reason:
            'the cursor must have advanced past the skipped oversized '
            'stream — repeating small1 forever (or getting stuck at '
            'big\'s own index) would mean the cursor never moved',
      );
      expect(secondOversized, hasLength(1));
      expect(secondOversized.single.streamId, equals(StreamId('big')));
    });
  });

  group('DigestBudgeter conservative cost model never underestimates', () {
    test('the fitted request always encodes within maxMessageBytes', () {
      final streams = [for (var i = 0; i < 5; i++) streamDigest('s$i', 3)];
      final all = [ChannelDigest(channelId: channelId, streams: streams)];

      final cost = itemCost(streams.first);
      final maxMessageBytes = baseSize() + cost * 3;

      final budgeter = DigestBudgeter(
        codec: codec,
        localNode: localNode,
        maxMessageBytes: maxMessageBytes,
      );

      final (digests, _) = budgeter.fitRequest(all);
      final encoded = codec
          .encode(DigestRequest(sender: localNode, digests: digests))
          .length;

      expect(
        encoded,
        lessThanOrEqualTo(maxMessageBytes),
        reason:
            'the conservative cost model must never underestimate the '
            'real encoded size, or a fitted message could still exceed '
            'the transport budget',
      );
    });

    test('the fitted response always encodes within maxMessageBytes', () {
      final big = streamDigest('big', 60);
      final small1 = streamDigest('small1', 1);
      final small2 = streamDigest('small2', 1);
      final flat = [
        (channel: channelId, digest: big),
        (channel: channelId, digest: small1),
        (channel: channelId, digest: small2),
      ];

      final maxMessageBytes = baseSize() + itemCost(small1);

      final budgeter = DigestBudgeter(
        codec: codec,
        localNode: localNode,
        maxMessageBytes: maxMessageBytes,
      );

      final (digests, _) = budgeter.fitResponse(flat);
      // The response wire shape (sender + digests) is structurally
      // identical to DigestRequest's, so encoding it as one is a faithful
      // stand-in for the real DigestResponse size.
      final encoded = codec
          .encode(DigestRequest(sender: localNode, digests: digests))
          .length;

      expect(encoded, lessThanOrEqualTo(maxMessageBytes));
    });
  });
}
