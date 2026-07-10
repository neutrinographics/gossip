import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';

import '../../support/test_network.dart';

void main() {
  group('Adverse Network Conditions', () {
    late TestNetwork network;
    final channelId = ChannelId('adverse-channel');
    final streamId = StreamId('data');

    setUp(() async {
      network = await TestNetwork.create(['node1', 'node2']);
      await network.connect('node1', 'node2');
      await network.setupChannel(channelId, streamId);
      await network.startAll();
    });

    tearDown(() async {
      await network.dispose();
    });

    test('one-way partition blocks sync until healed', () async {
      // Baseline: both nodes converge.
      await network['node1'].write(channelId, streamId, [1]);
      await network.runRounds(5);
      expect(await network.hasConverged(channelId, streamId), isTrue);

      // Block node1 → node2 only. node2's requests still reach node1, but
      // node1's responses (and pushes) never arrive, so nothing new syncs.
      network.partitionOneWay('node1', 'node2');
      await network['node1'].write(channelId, streamId, [2]);
      await network.runRounds(5);

      expect(await network['node2'].entryCount(channelId, streamId), equals(1));

      // Healing the direction restores convergence.
      network.healOneWay('node1', 'node2');
      await network.runRounds(15);

      expect(await network.hasConverged(channelId, streamId), isTrue);
      expect(await network['node2'].entryCount(channelId, streamId), equals(2));
    });

    test('delayed link holds messages in flight until released', () async {
      await network.runRounds(2);

      // Hold both directions: messages queue instead of being delivered.
      network.delayLink('node1', 'node2');
      network.delayLink('node2', 'node1');

      await network['node1'].write(channelId, streamId, [1]);
      await network.runRounds(2);

      // Messages are queued, visible as emergent backpressure.
      expect(network.inFlightCount('node1', 'node2'), greaterThan(0));
      expect(
        network['node1'].messagePort.pendingSendCount(network['node2'].id),
        equals(network.inFlightCount('node1', 'node2')),
      );
      expect(await network['node2'].entryCount(channelId, streamId), equals(0));

      // Releasing the links delivers the queued traffic and sync resumes.
      network.undelayLink('node1', 'node2');
      network.undelayLink('node2', 'node1');
      await network.runRounds(15);

      expect(network.inFlightCount('node1', 'node2'), equals(0));
      expect(await network.hasConverged(channelId, streamId), isTrue);
      expect(await network['node2'].entryCount(channelId, streamId), equals(1));
    });

    test(
      'releaseInFlight delivers held messages while link stays delayed',
      () async {
        network.delayLink('node1', 'node2');

        await network['node1'].write(channelId, streamId, [1]);
        await network.runRounds(1);
        final held = network.inFlightCount('node1', 'node2');
        expect(held, greaterThan(0));

        network.releaseInFlight(from: 'node1', to: 'node2');
        expect(network.inFlightCount('node1', 'node2'), equals(0));

        // New sends are still held because the link remains delayed.
        await network.runRounds(1);
        expect(network.inFlightCount('node1', 'node2'), greaterThan(0));

        network.undelayLink('node1', 'node2');
      },
    );

    test('gossip converges despite targeted message drops', () async {
      network.dropNext('node1', 'node2', count: 3);

      await network['node1'].write(channelId, streamId, [1]);
      await network.runRounds(15);

      expect(await network.hasConverged(channelId, streamId), isTrue);
      expect(await network['node2'].entryCount(channelId, streamId), equals(1));
    });

    test('gossip converges despite duplicated messages', () async {
      network.duplicateNext('node1', 'node2', count: 5);

      await network['node1'].write(channelId, streamId, [1]);
      await network.runRounds(10);

      expect(await network.hasConverged(channelId, streamId), isTrue);
      expect(await network['node2'].entryCount(channelId, streamId), equals(1));
    });

    test('corrupted messages do not corrupt synced entries', () async {
      // Corrupt the next message on the wire; the protocol should surface a
      // decode error (via ErrorCallback) rather than accept garbage, and
      // later rounds should converge cleanly.
      network.corruptNext(
        'node1',
        'node2',
        (bytes) => Uint8List.fromList(List.filled(bytes.length, 0xFF)),
      );

      await network['node1'].write(channelId, streamId, [42]);
      await network.runRounds(15);

      expect(await network.hasConverged(channelId, streamId), isTrue);
      final entries = await network['node2'].entries(channelId, streamId);
      expect(entries.single.payload, equals([42]));
    });
  });
}
