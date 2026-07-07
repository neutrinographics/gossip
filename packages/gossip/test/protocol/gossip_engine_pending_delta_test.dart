import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:gossip/src/protocol/values/stream_digest.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

/// M3: pending-delta tracking must be keyed per-(peer, channel, stream) and
/// use an adaptive timeout, so a stalled slow peer neither blocks requesting
/// the same stream from a faster peer nor gets a duplicate request issued
/// mid-transmission of a large page.
void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');

  DigestResponse digestFrom(dynamic peerId, {int seq = 3}) => DigestResponse(
    sender: peerId,
    digests: [
      ChannelDigest(
        channelId: channelId,
        streams: [
          StreamDigest(
            streamId: streamId,
            version: VersionVector({peerId: seq}),
          ),
        ],
      ),
    ],
  );

  group('GossipEngine pending-delta keying (M3)', () {
    test(
      'a pending delta request to one peer does not block requesting the '
      'same stream from another peer',
      () async {
        final h = GossipEngineTestHarness();
        final a = h.addPeer('peerA');
        final b = h.addPeer('peerB');
        h.createChannel('ch1', streamIds: ['s1']);

        final reqA = await h.engine.handleDigestResponse(digestFrom(a.id));
        final reqB = await h.engine.handleDigestResponse(digestFrom(b.id));

        expect(reqA, hasLength(1));
        expect(
          reqB,
          hasLength(1),
          reason:
              'the pending request to peerA must not suppress requesting the '
              'same stream from peerB (per-peer keying)',
        );

        await h.dispose();
      },
    );

    test(
      'a duplicate digest from the same peer is still deduped while a '
      'request is pending',
      () async {
        final h = GossipEngineTestHarness();
        final a = h.addPeer('peerA');
        h.createChannel('ch1', streamIds: ['s1']);

        final first = await h.engine.handleDigestResponse(digestFrom(a.id));
        final second = await h.engine.handleDigestResponse(digestFrom(a.id));

        expect(first, hasLength(1));
        expect(
          second,
          isEmpty,
          reason: 'same-peer duplicate must remain deduped (pending flag)',
        );

        await h.dispose();
      },
    );
  });

  group('GossipEngine adaptive pending-delta timeout (M3)', () {
    test(
      'defaults to a BLE-safe value before any delta round-trips are observed',
      () {
        final h = GossipEngineTestHarness();
        expect(
          h.engine.effectivePendingRequestTimeout,
          equals(const Duration(seconds: 8)),
        );
      },
    );

    test(
      'grows to cover an observed slow delta round-trip (so a page in '
      'flight is not re-requested)',
      () async {
        final h = GossipEngineTestHarness();
        final a = h.addPeer('peerA');
        h.createChannel('ch1', streamIds: ['s1']);

        // Issue a request (arms the pending flag at t0)...
        final req = await h.engine.handleDigestResponse(digestFrom(a.id));
        expect(req, hasLength(1));

        // ...the response arrives 6s later (a large page over a slow link).
        await h.timePort.advance(const Duration(seconds: 6));
        await h.engine.handleDeltaResponse(
          DeltaResponse(
            sender: a.id,
            channelId: channelId,
            streamId: streamId,
            entries: const [],
          ),
        );

        expect(
          h.engine.effectivePendingRequestTimeout.inMilliseconds,
          greaterThan(const Duration(seconds: 6).inMilliseconds),
          reason:
              'the timeout must exceed the observed 6s round-trip so a page '
              'in flight is never re-requested mid-transmission',
        );

        await h.dispose();
      },
    );
  });
}
