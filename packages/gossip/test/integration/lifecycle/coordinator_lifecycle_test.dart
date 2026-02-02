import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';

import '../../support/test_network.dart';

void main() {
  group('Coordinator Lifecycle', () {
    group('Peer management', () {
      test('peers can be added and queried', () async {
        final network = await TestNetwork.create(['local', 'peer1', 'peer2']);

        expect(network['local'].peers, isEmpty);

        await network['local'].coordinator.addPeer(network['peer1'].id);
        await network['local'].coordinator.addPeer(network['peer2'].id);

        expect(network['local'].peers.length, equals(2));
        expect(network['local'].reachablePeers.length, equals(2));

        await network['local'].coordinator.removePeer(network['peer1'].id);
        expect(network['local'].peers.length, equals(1));

        await network.dispose();
      });
    });

    group('Lifecycle state transitions', () {
      test('coordinator transitions through states correctly', () async {
        final network = await TestNetwork.create(['local']);
        final coord = network['local'].coordinator;

        expect(coord.state.name, equals('stopped'));

        await coord.start();
        expect(coord.state.name, equals('running'));

        await coord.stop();
        expect(coord.state.name, equals('stopped'));

        await coord.dispose();
        expect(coord.state.name, equals('disposed'));
      });

      test('disposed coordinator cannot be restarted', () async {
        final network = await TestNetwork.create(['local']);
        await network['local'].coordinator.dispose();

        expect(
          () => network['local'].coordinator.start(),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('Pause and resume', () {
      test('pause stops sync, resume continues', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('pause-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();
        await network.runRounds(3);

        // Write entry and sync
        await network['node1'].write(channelId, streamId, [1]);
        await network.runRounds(5);
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(1),
        );

        // Pause node2
        await network['node2'].coordinator.pause();
        expect(network['node2'].coordinator.state.name, equals('paused'));

        // Write more entries while node2 is paused
        await network['node1'].write(channelId, streamId, [2]);
        await network['node1'].write(channelId, streamId, [3]);
        await network.runRounds(5);

        // node2 should not have received new entries while paused
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(1),
        );

        // Resume node2
        await network['node2'].coordinator.resume();
        expect(network['node2'].coordinator.state.name, equals('running'));

        await network.runRounds(10);

        // Now node2 should have all entries
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(3),
        );

        await network.dispose();
      });

      test('multiple start/stop cycles preserve data', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('cycle-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);

        // Cycle 1: start, write, sync, stop
        await network.startAll();
        await network['node1'].write(channelId, streamId, [1]);
        await network.runRounds(5);
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(1),
        );
        await network['node1'].coordinator.stop();
        await network['node2'].coordinator.stop();

        // Cycle 2: start again, write more, sync
        await network['node1'].coordinator.start();
        await network['node2'].coordinator.start();
        await network['node1'].write(channelId, streamId, [2]);
        await network.runRounds(5);

        // Previous entry should still be there, plus new one
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(2),
        );

        // Cycle 3: one more round
        await network['node1'].coordinator.stop();
        await network['node2'].coordinator.stop();
        await network['node1'].coordinator.start();
        await network['node2'].coordinator.start();
        await network['node2'].write(channelId, streamId, [3]);
        await network.runRounds(5);

        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(3),
        );

        await network.dispose();
      });

      test('writes during stopped state are synced after restart', () async {
        final network = await TestNetwork.create(['node1', 'node2']);
        await network.connect('node1', 'node2');

        final channelId = ChannelId('stopped-write-channel');
        final streamId = StreamId('data');

        await network.setupChannel(channelId, streamId);
        await network.startAll();
        await network.runRounds(3);

        // Stop both coordinators
        await network['node1'].coordinator.stop();
        await network['node2'].coordinator.stop();

        // Write entries while stopped (local writes should still work)
        await network['node1'].write(channelId, streamId, [1]);
        await network['node1'].write(channelId, streamId, [2]);
        await network['node2'].write(channelId, streamId, [3]);

        // Entries are local only at this point
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(2),
        );
        expect(
          await network['node2'].entryCount(channelId, streamId),
          equals(1),
        );

        // Restart and sync
        await network['node1'].coordinator.start();
        await network['node2'].coordinator.start();
        await network.runRounds(10);

        // All entries should now be synced
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(
          await network['node1'].entryCount(channelId, streamId),
          equals(3),
        );

        await network.dispose();
      });
    });
  });
}
