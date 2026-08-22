import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/facade/coordinator.dart';
import 'package:gossip/src/facade/coordinator_config.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_channel_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/membership/infrastructure/in_memory_peer_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

void main() {
  final localNode = NodeId('local');
  final peerId = NodeId('peer1');
  final codec = ProtocolCodec();

  test(
    'adding a peer triggers an immediate gossip round with it (G2 wiring)',
    () async {
      final bus = InMemoryMessageBus();
      final timePort = InMemoryTimePort();
      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: InMemoryMessagePort(localNode, bus),
        timerPort: timePort,
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
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(
        digestRequests.length,
        equals(1),
        reason:
            'addPeer should kick off anti-entropy immediately rather than '
            'waiting for the random periodic round to select the new peer',
      );

      await sub.cancel();
      await peerPort.close();
      await coordinator.dispose();
    },
  );
}
