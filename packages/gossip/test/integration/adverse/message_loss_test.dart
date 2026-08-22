import 'package:test/test.dart';
import 'package:gossip/src/facade/coordinator_config.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';

import '../../support/test_network.dart';

/// Individual message loss and retry.
///
/// Verifies the pending-delta-request machinery end to end: losing a single
/// delta response mid-sync leaves the pull outstanding (no duplicate request
/// is issued while the pending flag is honoured), the pending-request timeout
/// expires, a later anti-entropy round retries, and the nodes converge.
/// Also verifies eventual convergence under sustained seeded probabilistic
/// loss on one link.
void main() {
  group('Message Loss and Retry', () {
    final channelId = ChannelId('loss-channel');
    final streamId = StreamId('data');

    // A fixed gossip interval keeps round timing predictable: with the
    // engine's ±20% jitter every scheduled round lands within [400ms, 600ms],
    // so each 1000ms advance fires exactly one gossip round per node.
    const config = CoordinatorConfig(
      gossipInterval: Duration(milliseconds: 500),
    );

    late TestNetwork network;

    setUp(() async {
      network = await TestNetwork.create(['node1', 'node2'], config: config);
      await network.connect('node1', 'node2');
      await network.setupChannel(channelId, streamId);
    });

    tearDown(() async {
      await network.dispose();
    });

    test('lost delta response: pull stays pending, timeout expires, '
        'a later round retries and converges', () async {
      // Write BEFORE starting so there is no reactive push: the entry can
      // only reach node2 through the digest/delta pull path, which is the
      // machinery under test.
      await network['node1'].write(channelId, streamId, [1]);

      // Hold node2 → node1 so node2's DeltaRequest is captured in flight
      // instead of being answered mid-advance. This lets us arm a drop for
      // exactly the DeltaResponse before releasing the request.
      network.delayLink('node2', 'node1');
      await network.startAll();

      // Advance node1 only: its gossip round sends a DigestRequest to
      // node2, which replies with a DigestResponse and — reciprocating the
      // push-pull exchange — a DeltaRequest for the entry it is missing.
      // Both replies are held on the delayed link; node2 has now marked
      // the pull as pending (at its own, un-advanced clock).
      await network['node1'].timePort.advance(const Duration(seconds: 1));

      expect(
        network['node2'].coordinator.gossipSyncActivity.outstandingPulls,
        equals(1),
        reason:
            'node2 reciprocated the digest with a DeltaRequest and '
            'must be tracking it as pending',
      );
      expect(
        network.inFlightCount('node2', 'node1'),
        greaterThanOrEqualTo(2),
        reason: 'DigestResponse and DeltaRequest are held on the link',
      );

      // Of the held messages, only the DeltaRequest provokes a reply from
      // node1 (its DigestResponse advertises nothing node1 lacks), so the
      // single armed drop deterministically kills exactly the
      // DeltaResponse — the one message carrying the entry.
      network.dropNext('node1', 'node2');
      network.undelayLink('node2', 'node1');
      await pumpEventQueue();

      expect(
        await network['node2'].entryCount(channelId, streamId),
        equals(0),
        reason: 'the delta response was lost in flight',
      );
      expect(
        network['node2'].coordinator.gossipSyncActivity.outstandingPulls,
        equals(1),
        reason: 'node2 never saw a response, so the pull is still pending',
      );

      // One more round: digests are exchanged again, but node2 must NOT
      // re-request yet — the pending request is younger than the timeout
      // (8s default before any delta round-trip is observed, and even the
      // adaptive minimum is 2s, well above the ~1s elapsed here).
      await network.runRounds(1);

      expect(
        await network['node2'].entryCount(channelId, streamId),
        equals(0),
        reason: 'retry is suppressed while the pending request is fresh',
      );
      expect(
        network['node2'].coordinator.gossipSyncActivity.outstandingPulls,
        equals(1),
        reason: 'the lost pull is still within its timeout window',
      );

      // Run past the 8s default pending-request timeout: the stale flag
      // expires, a later round's digest exchange re-issues the
      // DeltaRequest, and this time the response gets through.
      await network.runRounds(12);

      expect(
        await network.hasConverged(channelId, streamId),
        isTrue,
        reason: 'anti-entropy must retry after the pending timeout expires',
      );
      expect(await network['node2'].entryCount(channelId, streamId), equals(1));
      expect(
        network['node2'].coordinator.gossipSyncActivity.outstandingPulls,
        equals(0),
        reason: 'the retried pull completed, nothing is outstanding',
      );
    });

    test('sustained probabilistic loss on one link still converges', () async {
      await network.startAll();

      // 40% of everything node1 sends to node2 is lost — deterministic via
      // the seeded Random — for the whole test. The reverse direction is
      // healthy, mirroring an asymmetric radio link.
      network.setDropRate('node1', 'node2', 0.4, seed: 7);

      // Writes land after start, so reactive pushes AND anti-entropy
      // responses both contend with the loss.
      for (var i = 1; i <= 3; i++) {
        await network['node1'].write(channelId, streamId, [i]);
      }
      await network.runRounds(10);

      // Keep writing mid-loss on both sides: node2's entries cross the
      // healthy direction, node1's must survive repeated drops.
      await network['node1'].write(channelId, streamId, [4]);
      await network['node1'].write(channelId, streamId, [5]);
      await network['node2'].write(channelId, streamId, [100]);
      await network.runRounds(30);

      // The loss is never cleared: convergence must be reached THROUGH the
      // lossy link, purely by retrying across gossip rounds.
      expect(
        await network.hasConverged(channelId, streamId),
        isTrue,
        reason: 'anti-entropy must eventually converge despite 40% loss',
      );
      expect(await network['node1'].entryCount(channelId, streamId), equals(6));
      expect(await network['node2'].entryCount(channelId, streamId), equals(6));
    });
  });
}
