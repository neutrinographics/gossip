import 'dart:typed_data';

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
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

void main() {
  final localNode = NodeId('local');
  final peerId = NodeId('peer1');
  final codec = ProtocolCodec();

  test(
    'a local write is reactively pushed to a connected peer (G1 wiring)',
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
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

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
      await coordinator.dispose();
    },
  );
}
