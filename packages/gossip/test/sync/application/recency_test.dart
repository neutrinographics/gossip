import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/application/digest_rotation.dart';
import 'package:gossip/src/sync/application/peer_rotation.dart';
import 'package:gossip/src/sync/application/recency.dart';
import 'package:gossip/src/sync/application/rotation_key.dart';
import 'package:test/test.dart';

void main() {
  final a = RotationKey(ChannelId('a'), StreamId('s'));
  final b = RotationKey(ChannelId('b'));
  final c = RotationKey(ChannelId('c'));

  group('Recency', () {
    test('stamp assigns consecutive sequences in order', () {
      final r = Recency.initial.stamp([a, b]).stamp([c]);
      expect(r.sentAt(a), 0);
      expect(r.sentAt(b), 1);
      expect(r.sentAt(c), 2);
      expect(r.next, 3);
    });

    test('stamp leaves the input untouched', () {
      final before = Recency.initial.stamp([a]);
      before.stamp([b]);
      expect(before.sentAt(b), isNull);
      expect(before.next, 1);
      expect(Recency.initial.lastSent, isEmpty);
    });

    test('sentAt of an unstamped key is null', () {
      expect(Recency.initial.sentAt(a), isNull);
    });

    test('lastSent is unmodifiable', () {
      expect(
        () => Recency.initial.stamp([a]).lastSent[b] = 9,
        throwsUnsupportedError,
      );
    });

    test('a key without stream differs from the same channel with one', () {
      expect(RotationKey(ChannelId('a')), isNot(a));
      expect(RotationKey(ChannelId('a'), StreamId('s')), a);
    });
  });

  group('DigestRotation', () {
    final n1 = NodeId('n1');
    final n2 = NodeId('n2');

    test('of an unknown peer is a fresh PeerRotation', () {
      expect(DigestRotation.initial.of(n1), const PeerRotation());
    });

    test('forget removes only that peer', () {
      final stamped = PeerRotation(request: Recency.initial.stamp([a]));
      final rotation = DigestRotation.initial
          .withPeer(n1, stamped)
          .withPeer(n2, stamped)
          .forget(n1);
      expect(rotation.of(n1), const PeerRotation());
      expect(rotation.of(n2), stamped);
    });

    test('withPeer leaves the original untouched', () {
      final stamped = PeerRotation(announce: Recency.initial.stamp([b]));
      DigestRotation.initial.withPeer(n1, stamped);
      expect(DigestRotation.initial.byPeer, isEmpty);
    });

    test('copyWith replaces one list and keeps the others', () {
      final r = Recency.initial.stamp([a]);
      final p = const PeerRotation().copyWith(response: r);
      expect(p.response, r);
      expect(p.request, Recency.initial);
      expect(p.announce, Recency.initial);
    });

    test('PeerRotation equals by its three lists and hashes alike', () {
      final one = Recency.initial.stamp([a]);
      final same = Recency.initial.stamp([a]);

      expect(PeerRotation(request: one), PeerRotation(request: same));
      expect(
        PeerRotation(request: one).hashCode,
        PeerRotation(request: same).hashCode,
      );
      expect(PeerRotation(request: one), isNot(PeerRotation(response: one)));
      expect(PeerRotation(request: one), isNot(const PeerRotation()));
    });

    test('DigestRotation equals by peer and value, whatever the insertion '
        'order', () {
      final first = PeerRotation(request: Recency.initial.stamp([a]));
      final second = PeerRotation(announce: Recency.initial.stamp([b]));

      final forward = DigestRotation.initial
          .withPeer(n1, first)
          .withPeer(n2, second);
      final backward = DigestRotation.initial
          .withPeer(n2, second)
          .withPeer(n1, first);
      final other = DigestRotation.initial
          .withPeer(n1, first)
          .withPeer(n2, first);

      expect(forward, backward);
      expect(forward.hashCode, backward.hashCode);
      expect(forward, isNot(other));
    });

    test('equal values hash alike, and different contents usually do not', () {
      final one = Recency.initial.stamp([a, b]);
      final same = Recency.initial.stamp([a, b]);
      expect(one.hashCode, same.hashCode);
      expect(one.hashCode, isNot(Recency.initial.stamp([b, a]).hashCode));

      final rotation = DigestRotation.initial.withPeer(
        n1,
        PeerRotation(request: one),
      );
      final twin = DigestRotation.initial.withPeer(
        n1,
        PeerRotation(request: same),
      );
      expect(rotation.hashCode, twin.hashCode);
      expect(rotation.hashCode, isNot(DigestRotation.initial.hashCode));
    });
  });
}
