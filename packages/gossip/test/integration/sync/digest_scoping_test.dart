// Translates the whole-network pins of kt `integration/DigestScopingTest.kt`
// (gossip-kt): the join, and a hub holding more channels than the announce
// budget can name in one request.
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:test/test.dart';

import '../../support/test_network.dart';

void main() {
  final streamId = StreamId('events');

  group('Digest scoping scenarios (kt DigestScopingTest)', () {
    late TestNetwork network;

    tearDown(() async {
      await network.dispose();
    });

    /// Runs one round at a time until [entries] are held on every node: the
    /// pacer has backed off by the time the second side joins, so the first
    /// exchange after the join waits out the idle interval (kt awaits too).
    Future<void> awaitConverged(
      ChannelId channel, {
      required int entries,
      int maxRounds = 40,
    }) async {
      for (var i = 0; i < maxRounds; i++) {
        final counts = await network.entryCounts(channel, streamId);
        if (counts.values.every((c) => c == entries) &&
            await network.hasConverged(channel, streamId)) {
          return;
        }
        await network.runRounds(1);
      }
      fail(
        'no convergence on $channel in $maxRounds rounds: '
        '${await network.entryCounts(channel, streamId)}',
      );
    }

    test('a channel created on one side after first contact is shared within '
        'a round of the other side creating it', () async {
      network = await TestNetwork.create(['phone', 'server']);
      final errors = <Object>[];
      for (final name in ['phone', 'server']) {
        network[name].coordinator.errors.listen(errors.add);
      }
      final personal = ChannelId('user-1');
      final group = ChannelId('group-9');
      await network.connectAll();
      for (final name in ['phone', 'server']) {
        await network[name].createChannel(personal);
        await network[name].createStream(personal, streamId);
      }
      await network.startAll();
      await network['phone'].write(personal, streamId, [1]);
      await awaitConverged(personal, entries: 1);

      // The phone joins a group the server does not hold yet, and writes.
      await network['phone'].createChannel(group);
      await network['phone'].createStream(group, streamId);
      await network['phone'].write(group, streamId, [1]);
      await network.runRounds(3);
      expect(
        network['server'].coordinator.getChannel(group),
        isNull,
        reason: 'the server holds nothing it did not create',
      );

      // The server learns of the group and creates it.
      await network['server'].createChannel(group);
      await network['server'].createStream(group, streamId);
      await awaitConverged(group, entries: 1);
      expect(errors, isEmpty);
    });

    // 40 channels of 36-character ids overflow the 1 KB default announce
    // budget, so the pin exercises rotation.
    test('a hub with more channels than the announce budget still converges '
        'every shared channel', () async {
      network = await TestNetwork.create(['phone', 'hub']);
      final errors = <Object>[];
      for (final name in ['phone', 'hub']) {
        network[name].coordinator.errors.listen(errors.add);
      }
      final shared = ChannelId('shared');
      await network.connectAll();
      for (final name in ['phone', 'hub']) {
        await network[name].createChannel(shared);
        await network[name].createStream(shared, streamId);
      }
      for (var i = 1; i <= 40; i++) {
        final id = ChannelId(
          'hub-only-${i.toString().padLeft(2, '0')}-${'x' * 24}',
        );
        await network['hub'].createChannel(id);
        await network['hub'].createStream(id, streamId);
        await network['hub'].write(id, streamId, [i]);
      }
      await network.startAll();
      await network['hub'].write(shared, streamId, [1]);
      await network['phone'].write(shared, streamId, [2]);
      await awaitConverged(shared, entries: 2);
      expect(errors, isEmpty);
    });
  });
}
