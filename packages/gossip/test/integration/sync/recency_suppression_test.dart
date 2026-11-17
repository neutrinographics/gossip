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
/// The band: 600 steps of 100 ms are 60 s. A 600 ms step quantised every
/// wait to 1.2 s and hid the jitter, so a window of the whole interval
/// passed. At 100 ms steps the waits land anywhere in 0.8-1.2 s, and a
/// whole-interval window suppresses a round that came early in the jitter
/// although the last exchange is a full wait old, so the pair skips rounds.
/// A 200-seed simulation of the harness's arithmetic gave, per 30 s, 23-27
/// requests per pair with the full-interval window and 28-30 with the
/// jitter-floor window; at 30 s the floor separating them had no slack, so
/// the horizon is 60 s. Measured over 60 s: here 52 with the full-interval
/// window and 58 with the floor window, deterministic under the harness
/// seed (one isolate, settled by `pumpEventQueue`); gossip-kt measured 52
/// and 58-59. The band of 54-62 is shared by both twins: its floor sits 2
/// above the old figure, because the floor is what discriminates the old
/// behaviour, and its ceiling clears the highest new figure on either twin
/// by at least 3, still well under the two per interval an unsuppressed
/// pair would pay; gossip-kt's settle is a real-time delay, so its count
/// can vary run to run and the shared margin is sized for that.
///
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
    await runInterleavedRounds(network, 600);

    final observed = requests[0];
    expect(
      observed,
      inInclusiveRange(54, 62),
      reason:
          'a converged pair must send about one DigestRequest per '
          'interval (60 s at a 1 s interval), got $observed',
    );
  });
}
