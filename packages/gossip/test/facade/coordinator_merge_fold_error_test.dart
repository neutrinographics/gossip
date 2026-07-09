import 'dart:typed_data';

import 'package:gossip/gossip.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

/// A buggy app materializer: folding always throws.
class _ThrowingMaterializer extends StateMaterializer<int> {
  @override
  (int, String?) initial({required bool isReset}) => (0, null);

  @override
  int fold(int state, LogEntry entry) => throw StateError('app bug');
}

/// COR3-14: an app materializer throwing during the merge fold must not be
/// blamed on the peer as message corruption, must not suppress the
/// EntriesMerged event (the entries ARE merged and durable), and must
/// surface as a storage/application error.
void main() {
  test(
    'a throwing materializer in the merge path is reported as a storage '
    'error and EntriesMerged still fires',
    () async {
      final localNode = NodeId('local');
      final peerId = NodeId('peer-1');
      final channelId = ChannelId('ch1');
      final streamId = StreamId('s1');
      final bus = InMemoryMessageBus();
      final localPort = InMemoryMessagePort(localNode, bus);
      final peerPort = InMemoryMessagePort(peerId, bus);

      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: localPort,
        timerPort: InMemoryTimePort(),
      );
      final channel = await coordinator.createChannel(channelId);
      final stream = await channel.getOrCreateStream(streamId);
      await stream.registerMaterializer(_ThrowingMaterializer());
      // Initialize the materializer so the merge takes the incremental
      // fold path (where the fold throws).
      await stream.getState<int>();

      final errors = <SyncError>[];
      final events = <DomainEvent>[];
      final errorSub = coordinator.errors.listen(errors.add);
      final eventSub = coordinator.events.listen(events.add);

      await coordinator.start();
      await coordinator.addPeer(peerId);

      // An unsolicited (push-style) delta from the peer merges one entry;
      // the materializer's fold then throws.
      await peerPort.send(
        localNode,
        ProtocolCodec().encode(
          DeltaResponse(
            sender: peerId,
            channelId: channelId,
            streamId: streamId,
            entries: [
              LogEntry(
                author: peerId,
                sequence: 1,
                timestamp: Hlc(1000, 0),
                payload: Uint8List.fromList([1]),
              ),
            ],
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(
        events.whereType<EntriesMerged>(),
        hasLength(1),
        reason: 'the entries merged durably — the app must hear about them',
      );
      expect(errors, isNotEmpty, reason: 'the app bug must be reported');
      expect(
        errors.whereType<StorageSyncError>(),
        isNotEmpty,
        reason: 'an app-side fold failure is not peer corruption',
      );
      expect(
        errors.every(
          (e) => !e.message.contains('Malformed gossip message'),
        ),
        isTrue,
        reason: 'the peer must not be blamed for an app bug',
      );

      await errorSub.cancel();
      await eventSub.cancel();
      await coordinator.dispose();
      await peerPort.close();
    },
  );
}
