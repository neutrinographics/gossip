import 'dart:typed_data';

import 'package:gossip/src/coordinator/coordinator_config.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_types.dart';
import 'package:test/test.dart';

import '../../support/test_network.dart';

/// Round-level recency suppression end to end: a converged pair settles to
/// about one DigestRequest per gossip interval for the pair, not per node.
/// Without suppression each side initiates its own round every interval, so
/// the pair would pay about two per interval.
///
/// Translated from gossip-kt's `RecencySuppressionTest`
/// (`src/test/kotlin/com/neutrinographics/gossip/integration/RecencySuppressionTest.kt`);
/// the number this pins is the pair's, not a node's.
///
/// The band: 300 steps of 100 ms are 30 s. A 600 ms step quantised every
/// wait to 1.2 s and hid the jitter, so a window of the whole interval
/// passed. At 100 ms steps the waits land anywhere in 0.8-1.2 s, and a
/// whole-interval window suppresses a round that came early in the jitter
/// although the last exchange is a full wait old, so the pair skips rounds.
/// A 200-seed simulation of the harness's arithmetic gives 23-27 requests
/// per pair with the full-interval window and 28-30 with the jitter-floor
/// window (mean 28.7): the floor of 28 separates the two, and the ceiling
/// of 32 is headroom for settle ordering, still well under the two per
/// interval an unsuppressed pair would pay. The band is tight by design:
/// its floor of 28 sits one above the model's old maximum of 27 and at the
/// new model minimum, because the floor is what discriminates the old
/// behaviour. Observed here 27 with the full-interval window (at the
/// model's old maximum, so the floor has no slack below it) and 30 with
/// the floor window, deterministic under the harness seed (gossip-kt
/// observed 25 and 29 under its own harness).
/// Whole-interval steps are avoided on purpose: the nodes' clocks are
/// advanced one after another, so the second node reads a time one step
/// behind the first's and the exchange would sit exactly on the window
/// edge, which no real link does.
void main() {
  final channelId = ChannelId('recency-channel');
  final streamId = StreamId('data');

  /// Fixed cadence, so the suppression window is the jitter floor of one
  /// interval.
  const fixedGossip = CoordinatorConfig(
    gossipInterval: Duration(seconds: 1),
    adaptiveTimingEnabled: false,
  );

  bool isDigestRequest(Uint8List bytes) {
    try {
      return bytes[WireTypes.frameTypeOffset(bytes)] == WireTypes.digestRequest;
    } on ArgumentError {
      return false;
    }
  }

  /// Taps both directions of the pair, counting only DigestRequests.
  List<int> tapBoth(TestNetwork network, String a, String b) {
    final count = [0];
    for (final (from, to) in [(a, b), (b, a)]) {
      network.corruptLink(from, to, (bytes) {
        if (isDigestRequest(bytes)) count[0]++;
        return bytes;
      });
    }
    return count;
  }

  /// One 100 ms step at a time, settling after each node's tick.
  /// [TestNetwork.runRounds] advances every node back to back, so the
  /// second node's timer fires before the first one's request has been
  /// handled and both initiate in the same instant, a collision the
  /// suppression cannot see because the exchange has not been recorded
  /// yet. Settling between the ticks gives delivery the head start it has
  /// on a real link, where a frame lands in milliseconds against a
  /// seconds-long interval.
  Future<void> runInterleavedRounds(TestNetwork network, int rounds) async {
    for (var round = 0; round < rounds; round++) {
      for (final name in network.nodeNames) {
        await network[name].timePort.advance(const Duration(milliseconds: 100));
        await pumpEventQueue();
      }
    }
  }

  test('a converged pair exchanges about once per interval under real '
      'jitter', () async {
    final network = await TestNetwork.create([
      'node1',
      'node2',
    ], config: fixedGossip);
    addTearDown(network.dispose);
    await network.connect('node1', 'node2');
    await network.setupChannel(channelId, streamId);
    await network['node1'].write(channelId, streamId, [1]);
    await network.startAll();
    await runInterleavedRounds(network, 50);
    expect(await network.hasConverged(channelId, streamId), isTrue);
    expect(await network['node2'].entryCount(channelId, streamId), 1);

    final requests = tapBoth(network, 'node1', 'node2');
    await runInterleavedRounds(network, 300);

    final observed = requests[0];
    expect(
      observed,
      inInclusiveRange(28, 32),
      reason:
          'a converged pair must send about one DigestRequest per '
          'interval (30 s at a 1 s interval), got $observed',
    );
  });
}
