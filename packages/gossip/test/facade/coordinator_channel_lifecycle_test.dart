import 'package:gossip/gossip.dart';
import 'package:test/test.dart';

/// COR3-16: createChannel on an existing ID must be get-or-create — the
/// old behavior silently replaced the aggregate, wiping membership and
/// stream registrations (and the shipped example uses createChannel as
/// "join", entrenching the reset).
void main() {
  test('createChannel on an existing ID preserves the existing channel',
      () async {
    final localNode = NodeId('local');
    final coordinator = await Coordinator.create(
      localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
      channelRepository: InMemoryChannelRepository(),
      peerRepository: InMemoryPeerRepository(),
      entryRepository: InMemoryEntryRepository(),
    );
    final channelId = ChannelId('ch1');
    final streamId = StreamId('s1');
    final member = NodeId('peer-1');

    final channel = await coordinator.createChannel(channelId);
    await channel.getOrCreateStream(streamId);
    await channel.addMember(member);

    final events = <DomainEvent>[];
    final sub = coordinator.events.listen(events.add);

    // "Join" again with the same ID (the example's rejoin flow).
    final again = await coordinator.createChannel(channelId);

    expect(again.id, equals(channelId));
    expect(
      await again.streamIds,
      contains(streamId),
      reason: 'stream registrations must survive re-creation',
    );
    expect(
      await again.members,
      contains(member),
      reason: 'membership must survive re-creation',
    );

    await Future<void>.delayed(Duration.zero);
    expect(
      events.whereType<ChannelCreated>(),
      isEmpty,
      reason: 'no spurious ChannelCreated for an existing channel',
    );

    await sub.cancel();
    await coordinator.dispose();
  });
}
