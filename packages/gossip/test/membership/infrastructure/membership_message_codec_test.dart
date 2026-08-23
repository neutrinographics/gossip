import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/membership/domain/messages/ping.dart';
import 'package:gossip/src/membership/domain/messages/ack.dart';
import 'package:gossip/src/membership/domain/messages/ping_req.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:gossip/src/membership/infrastructure/membership_message_codec.dart';

void main() {
  group('MembershipMessageCodec', () {
    final codec = MembershipMessageCodec();

    test('round-trips Ping', () {
      final ping = Ping(sender: NodeId('peer1'), sequence: 42);

      final decoded = codec.decode(codec.encode(ping)) as Ping;
      expect(decoded.sender, equals(ping.sender));
      expect(decoded.sequence, equals(ping.sequence));
    });

    test('round-trips Ack', () {
      final ack = Ack(sender: NodeId('peer2'), sequence: 123);

      final decoded = codec.decode(codec.encode(ack)) as Ack;
      expect(decoded.sender, equals(ack.sender));
      expect(decoded.sequence, equals(ack.sequence));
    });

    test('round-trips PingReq', () {
      final pingReq = PingReq(
        sender: NodeId('peer1'),
        sequence: 456,
        target: NodeId('peer3'),
      );

      final decoded = codec.decode(codec.encode(pingReq)) as PingReq;
      expect(decoded.sender, equals(pingReq.sender));
      expect(decoded.sequence, equals(pingReq.sequence));
      expect(decoded.target, equals(pingReq.target));
    });

    test('decode returns null for a frame from the sync family', () {
      final digestRequest = DigestRequest(sender: NodeId('peer1'), digests: []);
      final bytes = SyncMessageCodec().encode(digestRequest);

      expect(codec.decode(bytes), isNull);
    });

    test('decode throws ArgumentError for empty bytes (own malformed-frame '
        'behavior)', () {
      expect(
        () => codec.decode(Uint8List(0)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'Cannot decode empty bytes',
          ),
        ),
      );
    });

    test('decode throws on malformed JSON for its own family type byte', () {
      // Type byte 0 (Ping) with a body that isn't valid JSON.
      final bytes = Uint8List.fromList([0, ...utf8.encode('not json')]);

      expect(() => codec.decode(bytes), throwsA(isA<Object>()));
    });

    test('decode throws ArgumentError for a type byte outside every known '
        'family (genuinely corrupt, not just "not mine")', () {
      // 255 belongs to neither membership (0-2) nor sync (3-6) — unlike
      // the sync-family test above, this must NOT be treated as routine
      // foreign traffic.
      final bytes = Uint8List.fromList([255, 0, 1, 2, 3]);

      expect(
        () => codec.decode(bytes),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'Unknown message type: 255',
          ),
        ),
      );
    });
  });
}
