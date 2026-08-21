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
  int tapBoth(TestNetwork network, List<int> counter) {
    network.corruptLink('a', 'b', (bytes) {
      counter[0]++;
      return bytes;
    });
    network.corruptLink('b', 'a', (bytes) {
      counter[0]++;
      return bytes;
    });
    return counter[0];
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
    final early = counter[0];
    await network.runRounds(60); // let backoff take hold
    counter[0] = 0;
    await network.runRounds(30); // late idle window, same width as early
    final late = counter[0];

    expect(late, lessThan(early),
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
        reason: 'news must snap the cadence back — the reactive push '
            'plus a reset periodic round converge fast even from deep idle');
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

    // Within the ceiling (30 simulated seconds), anti-entropy repairs it.
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
