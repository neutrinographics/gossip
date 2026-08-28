import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/membership/domain/messages/ping.dart';
import 'package:gossip/src/membership/domain/messages/ack.dart';
import 'package:gossip/src/membership/domain/messages/ping_req.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';
import 'package:gossip/src/membership/infrastructure/membership_message_codec.dart';

void main() {
  group('MembershipMessageCodec', () {
    final codec = MembershipMessageCodec();

    Map<String, dynamic> jsonOf(Uint8List encoded) =>
        jsonDecode(utf8.decode(encoded.sublist(1))) as Map<String, dynamic>;

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

    group('encode-side wire pinning', () {
      // Every literal type byte and key set below is copied by hand from
      // the codec, not read from WireTypes or the codec's own encoder. A
      // round-trip test (decode(encode(x))) stays green even if the
      // encoder and decoder drift together — e.g. both sides rename a
      // JSON key, or both sides get the same (wrong) type-byte edit. An
      // independently-sourced literal is the only thing that can catch
      // that: it fails when THIS codec's output differs from what a
      // previously-deployed peer's codec would still expect.
      test('Ping encodes with wire type byte 0 and the sender/sequence '
          'key set', () {
        final ping = Ping(sender: NodeId('peer1'), sequence: 42);
        final encoded = codec.encode(ping);

        expect(encoded[0], equals(0));
        expect(jsonOf(encoded).keys.toSet(), equals({'sender', 'sequence'}));
      });

      test('Ack encodes with wire type byte 1 and the sender/sequence '
          'key set', () {
        final ack = Ack(sender: NodeId('peer2'), sequence: 123);
        final encoded = codec.encode(ack);

        expect(encoded[0], equals(1));
        expect(jsonOf(encoded).keys.toSet(), equals({'sender', 'sequence'}));
      });

      test('PingReq encodes with wire type byte 2 and the '
          'sender/sequence/target key set', () {
        final pingReq = PingReq(
          sender: NodeId('peer1'),
          sequence: 456,
          target: NodeId('peer3'),
        );
        final encoded = codec.encode(pingReq);

        expect(encoded[0], equals(2));
        expect(
          jsonOf(encoded).keys.toSet(),
          equals({'sender', 'sequence', 'target'}),
        );
      });
    });

    test('decode returns null for a frame from the sync family', () {
      final digestRequest = DigestRequest(sender: NodeId('peer1'), digests: []);
      // v1 (unprefixed): MembershipMessageCodec's own marker-awareness is
      // out of this task's scope, so this probes its existing
      // sibling-family detection with the frame shape it already handles.
      final bytes = SyncMessageCodec(
        wireVersion: WireVersion.v1,
      ).encode(digestRequest);

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
