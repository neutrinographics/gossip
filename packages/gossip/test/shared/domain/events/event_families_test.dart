import 'package:test/test.dart';
import 'package:gossip/gossip.dart';

/// Part 2 spec: per-context sealed families under an abstract shared base.
void main() {
  final now = DateTime(2024, 1, 15, 12, 0, 0);

  test('sync events are SyncEvents; membership events are MembershipEvents',
      () {
    expect(
      ChannelCreated(ChannelId('c'), occurredAt: now),
      isA<SyncEvent>(),
    );
    expect(PeerAdded(NodeId('n'), occurredAt: now), isA<MembershipEvent>());
    // Both families still share the base — consumers of the public
    // Stream<DomainEvent> are unaffected.
    expect(PeerAdded(NodeId('n'), occurredAt: now), isA<DomainEvent>());
  });
}
