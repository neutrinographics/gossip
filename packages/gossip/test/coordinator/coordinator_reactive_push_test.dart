import 'dart:typed_data';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/coordinator/coordinator_config.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';
import 'package:test/test.dart';

import '../support/coordinator_builder.dart';
import '../support/pump.dart';

void main() {
  final peerId = NodeId('peer1');
  final codec = SyncMessageCodec(wireVersion: WireVersion.v2);

  test('a local write is reactively pushed to a connected peer', () async {
    final bus = InMemoryMessageBus();
    final timePort = InMemoryTimePort();
    final coordinator = await createTestCoordinator(
      bus: bus,
      timePort: timePort,
      // Long periodic intervals so only the reactive push fires within
      // the debounce window under test.
      config: const CoordinatorConfig(
        gossipInterval: Duration(seconds: 100),
        probeInterval: Duration(seconds: 100),
        pingTimeout: Duration(seconds: 100),
        startupGracePeriod: Duration.zero,
      ),
    );

    final peerPort = InMemoryMessagePort(peerId, bus);
    final pushes = <DeltaResponse>[];
    final sub = peerPort.incoming.listen((msg) {
      final decoded = codec.decode(msg.bytes);
      if (decoded is DeltaResponse) pushes.add(decoded);
    });

    await coordinator.start();
    await coordinator.addPeer(peerId);
    final channel = await coordinator.createChannel(ChannelId('ch1'));
    final stream = await channel.getOrCreateStream(StreamId('s1'));

    await stream.append(Uint8List.fromList([42]));

    // Advance past the reactive-push debounce window.
    await timePort.advance(const Duration(milliseconds: 150));
    await pumpUntil(
      () => pushes.isNotEmpty,
      describe: 'the reactive push reaching the peer',
    );

    expect(
      pushes.length,
      equals(1),
      reason:
          'a local write should be pushed to the peer reactively, not wait '
          'for the next periodic round',
    );
    expect(
      pushes.single.entries.single.payload,
      equals(Uint8List.fromList([42])),
    );

    await sub.cancel();
    await peerPort.close();
  });
}
