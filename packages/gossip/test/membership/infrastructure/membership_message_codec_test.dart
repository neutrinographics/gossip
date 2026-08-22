import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/protocol/messages/ping.dart';
import 'package:gossip/src/protocol/messages/ack.dart';
import 'package:gossip/src/protocol/messages/ping_req.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:gossip/src/membership/infrastructure/membership_message_codec.dart';

void main() {
  group('MembershipMessageCodec', () {
    final codec = MembershipMessageCodec();
    final legacyCodec = ProtocolCodec();

    test(
      'wire-freeze: round-trips Ping byte-identically with ProtocolCodec',
      () {
        final ping = Ping(sender: NodeId('peer1'), sequence: 42);

        final bytesFromNew = codec.encode(ping);
        final bytesFromLegacy = legacyCodec.encode(ping);
        expect(bytesFromNew, equals(bytesFromLegacy));

        // encode with new, decode with legacy
        final decodedByLegacy = legacyCodec.decode(bytesFromNew) as Ping;
        expect(decodedByLegacy.sender, equals(ping.sender));
        expect(decodedByLegacy.sequence, equals(ping.sequence));

        // encode with legacy, decode with new
        final decodedByNew = codec.decode(bytesFromLegacy) as Ping;
        expect(decodedByNew.sender, equals(ping.sender));
        expect(decodedByNew.sequence, equals(ping.sequence));
      },
    );

    test(
      'wire-freeze: round-trips Ack byte-identically with ProtocolCodec',
      () {
        final ack = Ack(sender: NodeId('peer2'), sequence: 123);

        final bytesFromNew = codec.encode(ack);
        final bytesFromLegacy = legacyCodec.encode(ack);
        expect(bytesFromNew, equals(bytesFromLegacy));

        final decodedByLegacy = legacyCodec.decode(bytesFromNew) as Ack;
        expect(decodedByLegacy.sender, equals(ack.sender));
        expect(decodedByLegacy.sequence, equals(ack.sequence));

        final decodedByNew = codec.decode(bytesFromLegacy) as Ack;
        expect(decodedByNew.sender, equals(ack.sender));
        expect(decodedByNew.sequence, equals(ack.sequence));
      },
    );

    test(
      'wire-freeze: round-trips PingReq byte-identically with ProtocolCodec',
      () {
        final pingReq = PingReq(
          sender: NodeId('peer1'),
          sequence: 456,
          target: NodeId('peer3'),
        );

        final bytesFromNew = codec.encode(pingReq);
        final bytesFromLegacy = legacyCodec.encode(pingReq);
        expect(bytesFromNew, equals(bytesFromLegacy));

        final decodedByLegacy = legacyCodec.decode(bytesFromNew) as PingReq;
        expect(decodedByLegacy.sender, equals(pingReq.sender));
        expect(decodedByLegacy.sequence, equals(pingReq.sequence));
        expect(decodedByLegacy.target, equals(pingReq.target));

        final decodedByNew = codec.decode(bytesFromLegacy) as PingReq;
        expect(decodedByNew.sender, equals(pingReq.sender));
        expect(decodedByNew.sequence, equals(pingReq.sequence));
        expect(decodedByNew.target, equals(pingReq.target));
      },
    );

    test('decode returns null for a frame from the sync family', () {
      final digestRequest = DigestRequest(sender: NodeId('peer1'), digests: []);
      final bytes = legacyCodec.encode(digestRequest);

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
