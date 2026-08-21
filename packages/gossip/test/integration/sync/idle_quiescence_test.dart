import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';

import '../../support/test_network.dart';

/// Spec 2026-08-20 acceptance: an idle converged network's traffic decays
/// (structural inequality, not wall rates — InMemoryTimePort quantizes
/// RTT to the advance step), news snaps it back, and a lost push is
/// repaired within the 30s ceiling.
void main() {
  final channelId = ChannelId('quiesce-ch');
  final streamId = StreamId('quiesce-s');

  /// Counts messages crossing both directions of the a<->b link.
  void tapBoth(TestNetwork network, List<int> counter) {
    network.corruptLink('a', 'b', (bytes) {
      counter[0]++;
      return bytes;
    });
    network.corruptLink('b', 'a', (bytes) {
      counter[0]++;
      return bytes;
    });
  }

  test('idle traffic decays after convergence and stays low', () async {
    final network = await TestNetwork.create(['a', 'b']);
    await network.connectAll();
    await network.setupChannel(channelId, streamId);
    await network.startAll();
    await network['a'].write(channelId, streamId, [1]);
    await network.runRounds(10);
    expect(await network.hasConverged(channelId, streamId), isTrue);

    final counter = [0];
    tapBoth(network, counter);

    await network.runRounds(30); // early idle window
    final earlyCount = counter[0];
    await network.runRounds(60); // let backoff take hold
    counter[0] = 0;
    await network.runRounds(30); // late idle window, same width as early
    final lateCount = counter[0];

    expect(lateCount, lessThan(earlyCount),
        reason: 'quiescence pacing must reduce idle traffic over time');
    await network.dispose();
  });

  test('a write snaps the network back and converges promptly', () async {
    final network = await TestNetwork.create(['a', 'b']);
    await network.connectAll();
    await network.setupChannel(channelId, streamId);
    await network.startAll();
    await network['a'].write(channelId, streamId, [1]);
    await network.runRounds(10);
    await network.runRounds(90); // deep idle: both loops at ceiling

    await network['a'].write(channelId, streamId, [2]);
    await network.runRounds(5);

    expect(await network.hasConverged(channelId, streamId), isTrue,
        reason: 'a write from deep idle must converge promptly via the '
            'reactive push, even before the periodic loop wakes back up');
    await network.dispose();
  });

  test(
      'deep idle stretches the gossip interval toward the ceiling and a '
      'write snaps it back', () async {
    final network = await TestNetwork.create(['a', 'b']);
    await network.connectAll();
    await network.setupChannel(channelId, streamId);
    await network.startAll();
    await network['a'].write(channelId, streamId, [1]);
    await network.runRounds(10);
    await network.runRounds(90); // deep idle: stretch toward the ceiling

    final idleInterval = network['a'].effectiveGossipInterval;
    expect(idleInterval, isNotNull);
    expect(idleInterval!.inSeconds, greaterThan(10),
        reason: 'quiescence pacer must stretch the idle interval near the '
            '30s ceiling');

    await network['a'].write(channelId, streamId, [2]);

    final resetInterval = network['a'].effectiveGossipInterval;
    expect(resetInterval, isNotNull);
    expect(resetInterval!.inSeconds, lessThanOrEqualTo(5),
        reason: 'news must snap the pacer back to the active adaptive '
            'band (<=5s clamp), directly verifying the cadence reset '
            'rather than only inferring it from convergence');
    await network.dispose();
  });

  test('a lost reactive push is repaired within the 30s ceiling', () async {
    final network = await TestNetwork.create(['a', 'b']);
    await network.connectAll();
    await network.setupChannel(channelId, streamId);
    await network.startAll();
    await network['a'].write(channelId, streamId, [1]);
    await network.runRounds(10);
    await network.runRounds(90); // deep idle

    // Swallow the push (and its debounced flush is one message).
    network.dropNext('a', 'b', count: 1);
    await network['a'].write(channelId, streamId, [2]);

    // Guard: let the 150ms debounced flush fire (and be dropped) without
    // giving the still-far-off periodic round — scheduled while deeply
    // idle, so its remaining delay is nowhere near elapsed yet — a chance
    // to fire too. If this converges anyway, the push wasn't actually the
    // thing that got dropped, and the assertion below would pass vacuously.
    await network.runRounds(1, advanceMs: 200);
    expect(await network.hasConverged(channelId, streamId), isFalse,
        reason: 'the reactive push must actually have been lost here — '
            'otherwise the repair below is not exercising the lost-push '
            'path at all');

    // Within the ceiling (30 simulated seconds plus margin), anti-entropy
    // repairs it.
    await network.runRounds(35);
    expect(await network.hasConverged(channelId, streamId), isTrue,
        reason: 'the safety net must repair a lost push within 30s');
    await network.dispose();
  });

  test('deep idleness never marks healthy peers unreachable', () async {
    final network = await TestNetwork.create(['a', 'b']);
    await network.connectAll();
    await network.setupChannel(channelId, streamId);
    await network.startAll();
    await network.runRounds(120);

    expect(network['a'].reachablePeers, hasLength(1));
    expect(network['b'].reachablePeers, hasLength(1));
    await network.dispose();
  });
}
