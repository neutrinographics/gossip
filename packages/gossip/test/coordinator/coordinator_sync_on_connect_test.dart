import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/coordinator/coordinator_config.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:test/test.dart';

import '../support/coordinator_builder.dart';
import '../support/pump.dart';

void main() {
  final peerId = NodeId('peer1');
  final codec = SyncMessageCodec();

  test(
    'adding a peer triggers an immediate gossip round with it (G2 wiring)',
    () async {
      final bus = InMemoryMessageBus();
      final timePort = InMemoryTimePort();
      final coordinator = await createTestCoordinator(
        bus: bus,
        timePort: timePort,
        // Long periodic intervals: only sync-on-connect can produce a
        // DigestRequest within the test window.
        config: const CoordinatorConfig(
          gossipInterval: Duration(seconds: 100),
          probeInterval: Duration(seconds: 100),
          pingTimeout: Duration(seconds: 100),
          startupGracePeriod: Duration.zero,
        ),
      );

      final peerPort = InMemoryMessagePort(peerId, bus);
      final digestRequests = <DigestRequest>[];
      final sub = peerPort.incoming.listen((msg) {
        final decoded = codec.decode(msg.bytes);
        if (decoded is DigestRequest) digestRequests.add(decoded);
      });

      await coordinator.start();
      final channel = await coordinator.createChannel(ChannelId('ch1'));
      await channel.getOrCreateStream(StreamId('s1'));

      // No periodic round has fired yet (interval is 100s).
      await coordinator.addPeer(peerId);
      await pumpUntil(
        () => digestRequests.isNotEmpty,
        describe: 'addPeer triggering an immediate sync-on-connect round',
      );

      expect(
        digestRequests.length,
        equals(1),
        reason:
            'addPeer should kick off anti-entropy immediately rather than '
            'waiting for the random periodic round to select the new peer',
      );

      await sub.cancel();
      await peerPort.close();
    },
  );
}
