import 'dart:typed_data';

import 'package:gossip/src/coordinator/coordinator_config.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/sync/domain/events/sync_events.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/messages/digest_response.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:test/test.dart';

import '../support/coordinator_builder.dart';
import '../support/pump.dart';

/// An [InMemoryMessageBus] that records every frame handed to [deliver],
/// so a test can assert on the raw bytes actually placed on the wire
/// without having to intercept each coordinator's own [InMemoryMessagePort].
class _SnoopingBus extends InMemoryMessageBus {
  final List<Uint8List> frames = [];

  @override
  void deliver(NodeId destination, NodeId sender, Uint8List bytes) {
    frames.add(bytes);
    super.deliver(destination, sender, bytes);
  }
}

void main() {
  test('the default wire version is v1', () {
    expect(CoordinatorConfig.defaults.wireVersion, equals(WireVersion.v1));
  });

  test('the append-time payload cap under the default 30KB budget: v1 ~7.4KB '
      'vs v2 ~22.1KB', () {
    // Pins the ruled consequence of the v1 default (spec §11 decision
    // 5): flipping wireVersion changes the max payload EventStream.append
    // accepts, not just the wire framing. Same budget, both versions, so
    // the ~3x gap is explicit in the suite rather than implied.
    final budget = CoordinatorConfig.defaults.maxMessageBytes;

    expect(
      SyncMessageCodec.maxEntryPayloadForBudget(budget, WireVersion.v1),
      equals(7552),
    );
    expect(
      SyncMessageCodec.maxEntryPayloadForBudget(budget, WireVersion.v2),
      equals(22656),
    );
  });

  test(
    'two default-config coordinators sync over unprefixed v1 frames',
    () async {
      final bus = _SnoopingBus();
      final nodeA = NodeId('nodeA');
      final nodeB = NodeId('nodeB');

      final a = await createTestCoordinator(
        nodeId: 'nodeA',
        bus: bus,
        timePort: InMemoryTimePort(),
        start: true,
      );
      final b = await createTestCoordinator(
        nodeId: 'nodeB',
        bus: bus,
        timePort: InMemoryTimePort(),
        start: true,
      );

      final channelA = await a.createChannel(ChannelId('ch1'));
      await channelA.addMember(nodeB);
      final streamA = await channelA.getOrCreateStream(StreamId('s1'));

      final channelB = await b.createChannel(ChannelId('ch1'));
      await channelB.addMember(nodeA);
      await channelB.getOrCreateStream(StreamId('s1'));

      await streamA.append(Uint8List.fromList([1, 2, 3]));

      final mergedOnB = <EntriesMerged>[];
      b.events.listen((event) {
        if (event is EntriesMerged) mergedOnB.add(event);
      });

      await a.addPeer(nodeB);
      await b.addPeer(nodeA);

      await pumpUntil(
        () => mergedOnB.isNotEmpty,
        describe: 'node B merging the entry appended on node A',
      );

      expect(
        mergedOnB.single.entries.single.payload,
        equals(Uint8List.fromList([1, 2, 3])),
        reason: 'v1 int-array payloads should decode fine at the receiver',
      );
      expect(bus.frames, isNotEmpty);
      for (final frame in bus.frames) {
        expect(
          frame.first,
          lessThanOrEqualTo(0x06),
          reason:
              'a default-config (v1) coordinator must never emit a marker-'
              'prefixed frame — got first byte 0x${frame.first.toRadixString(16)}',
        );
      }
    },
  );

  test('wireVersion v2 emits marked frames and still syncs', () async {
    final bus = _SnoopingBus();
    final nodeA = NodeId('nodeA');
    final nodeB = NodeId('nodeB');
    const config = CoordinatorConfig(wireVersion: WireVersion.v2);

    final a = await createTestCoordinator(
      nodeId: 'nodeA',
      bus: bus,
      timePort: InMemoryTimePort(),
      config: config,
      start: true,
    );
    final b = await createTestCoordinator(
      nodeId: 'nodeB',
      bus: bus,
      timePort: InMemoryTimePort(),
      config: config,
      start: true,
    );

    final channelA = await a.createChannel(ChannelId('ch1'));
    await channelA.addMember(nodeB);
    final streamA = await channelA.getOrCreateStream(StreamId('s1'));

    final channelB = await b.createChannel(ChannelId('ch1'));
    await channelB.addMember(nodeA);
    await channelB.getOrCreateStream(StreamId('s1'));

    await streamA.append(Uint8List.fromList([9, 8, 7]));

    final mergedOnB = <EntriesMerged>[];
    b.events.listen((event) {
      if (event is EntriesMerged) mergedOnB.add(event);
    });

    await a.addPeer(nodeB);
    await b.addPeer(nodeA);

    await pumpUntil(
      () => mergedOnB.isNotEmpty,
      describe: 'node B merging the entry appended on node A over v2 frames',
    );

    expect(
      mergedOnB.single.entries.single.payload,
      equals(Uint8List.fromList([9, 8, 7])),
    );
    expect(bus.frames, isNotEmpty);
    for (final frame in bus.frames) {
      expect(
        frame.first,
        equals(0xF2),
        reason:
            'a WireVersion.v2-configured coordinator must prefix every '
            'frame with the marker byte — got 0x${frame.first.toRadixString(16)}',
      );
    }
  });

  test('a v2 frame is handled once, with zero errors emitted', () async {
    final bus = InMemoryMessageBus();
    final coordinator = await createTestCoordinator(
      bus: bus,
      timePort: InMemoryTimePort(),
      start: true,
    );

    final peerId = NodeId('peer1');
    final peerPort = InMemoryMessagePort(peerId, bus);
    final decodeCodec = SyncMessageCodec(wireVersion: WireVersion.v1);
    final responses = <DigestResponse>[];
    final sub = peerPort.incoming.listen((msg) {
      final decoded = decodeCodec.decode(msg.bytes);
      if (decoded is DigestResponse) responses.add(decoded);
    });

    final v2Frame = SyncMessageCodec(
      wireVersion: WireVersion.v2,
    ).encode(DigestRequest(sender: peerId, digests: const []));
    await peerPort.send(NodeId('local'), v2Frame);

    await pumpUntil(
      () => responses.isNotEmpty,
      describe: 'a DigestResponse reply to the injected v2 DigestRequest',
    );

    expect(
      responses.length,
      equals(1),
      reason:
          'the v2 frame must be handled exactly once, by the sync '
          'engine only — the membership codec must decode it to null '
          '(sibling-family "not mine"), not throw a second ArgumentError',
    );
    expect(recordedErrorsOf(coordinator), isEmpty);

    await sub.cancel();
    await peerPort.close();
  });
}
