import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';

import '../../support/test_network.dart';

void main() {
  group('Topology Sync', () {
    group('Network topologies', () {
      test(
        'chain topology - entries propagate through intermediate node',
        () async {
          // A -- B -- C (no direct A-C link)
          final network = await TestNetwork.create(['nodeA', 'nodeB', 'nodeC']);
          await network.connectChain(['nodeA', 'nodeB', 'nodeC']);

          final channelId = ChannelId('chain-channel');
          final streamId = StreamId('data');

          await network.setupChannel(channelId, streamId);
          await network['nodeA'].write(channelId, streamId, [0xAA]);

          await network.startAll();
          // Need more rounds for multi-hop propagation
          await network.runRounds(15);

          // Entry should reach nodeC through nodeB
          expect(await network.hasConverged(channelId, streamId), isTrue);
          expect(
            await network['nodeC'].entryCount(channelId, streamId),
            equals(1),
          );

          // Write from nodeC should reach nodeA
          await network['nodeC'].write(channelId, streamId, [0xCC]);
          await network.runRounds(15);

          expect(
            await network['nodeA'].entryCount(channelId, streamId),
            equals(2),
          );

          await network.dispose();
        },
      );

      test('star topology - hub relays between spokes', () async {
        // Hub in center, spokes only connect to hub
        final network = await TestNetwork.create([
          'hub',
          'spoke1',
          'spoke2',
          'spoke3',
        ]);
        await network.connectStar('hub', ['spoke1', 'spoke2', 'spoke3']);

        final channelId = ChannelId('star-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);

        // Each spoke writes an entry
        await network['spoke1'].write(channelId, streamId, [1]);
        await network['spoke2'].write(channelId, streamId, [2]);
        await network['spoke3'].write(channelId, streamId, [3]);

        await network.startAll();
        await network.runRounds(20);

        // All nodes should have all entries (relayed through hub)
        expect(await network.hasConverged(channelId, streamId), isTrue);
        for (final node in ['hub', 'spoke1', 'spoke2', 'spoke3']) {
          expect(
            await network[node].entryCount(channelId, streamId),
            equals(3),
          );
        }

        await network.dispose();
      });

      test('ring topology - entries propagate around the ring', () async {
        // A -- B -- C -- D -- A (circular)
        final network = await TestNetwork.create([
          'nodeA',
          'nodeB',
          'nodeC',
          'nodeD',
        ]);
        await network.connectRing(['nodeA', 'nodeB', 'nodeC', 'nodeD']);

        final channelId = ChannelId('ring-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network['nodeA'].write(channelId, streamId, [0xAA]);

        await network.startAll();
        await network.runRounds(20);

        // All nodes should have the entry
        expect(await network.hasConverged(channelId, streamId), isTrue);

        await network.dispose();
      });
    });
  });
}
