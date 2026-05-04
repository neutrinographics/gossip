import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/infrastructure/codec/frame_codec.dart';

void main() {
  group('FrameEncoder', () {
    test('emits a single chunk when payload + length prefix fits the MTU', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 100);
      expect(chunks, hasLength(1));
      expect(chunks.first, hasLength(4 + 5));
      // length prefix: big-endian 5
      expect(chunks.first.sublist(0, 4), equals([0, 0, 0, 5]));
      expect(chunks.first.sublist(4), equals([1, 2, 3, 4, 5]));
    });

    test('splits across multiple chunks when payload exceeds MTU', () {
      // mtuPayloadSize = 8. Length prefix takes 4 bytes of the first chunk.
      // Payload = 20 bytes. First chunk carries 4 prefix bytes + 4 payload bytes;
      // remaining 16 payload bytes need ceil(16/8) = 2 chunks.
      final payload = Uint8List.fromList(List.generate(20, (i) => i));
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 8);
      expect(chunks, hasLength(3));
      expect(chunks[0], hasLength(8));
      expect(chunks[0].sublist(0, 4), equals([0, 0, 0, 20]));
      expect(chunks[0].sublist(4), equals([0, 1, 2, 3]));
      expect(chunks[1], hasLength(8));
      expect(chunks[1], equals([4, 5, 6, 7, 8, 9, 10, 11]));
      expect(chunks[2], hasLength(8));
      expect(chunks[2], equals([12, 13, 14, 15, 16, 17, 18, 19]));
    });

    test('throws on empty payload', () {
      expect(
        () => FrameEncoder.encode(Uint8List(0), mtuPayloadSize: 20),
        throwsArgumentError,
      );
    });

    test('throws when mtuPayloadSize is too small to hold the prefix', () {
      // length prefix is 4 bytes; if the chunk can't hold even that, encoding
      // is impossible.
      expect(
        () => FrameEncoder.encode(
          Uint8List.fromList([1]),
          mtuPayloadSize: 3,
        ),
        throwsArgumentError,
      );
    });

    test('rejects payloads larger than 32KB', () {
      final payload = Uint8List(32 * 1024 + 1);
      expect(
        () => FrameEncoder.encode(payload, mtuPayloadSize: 200),
        throwsArgumentError,
      );
    });
  });

  group('FrameDecoder', () {
    test('round-trips a small payload through encode → decode', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 100);
      final decoder = FrameDecoder();
      final decoded = <Uint8List>[];
      for (final chunk in chunks) {
        decoded.addAll(decoder.feed(chunk));
      }
      expect(decoded, hasLength(1));
      expect(decoded.first, equals(payload));
    });

    test('round-trips a chunked payload', () {
      final payload = Uint8List.fromList(List.generate(20, (i) => i));
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 8);
      final decoder = FrameDecoder();
      final decoded = <Uint8List>[];
      for (final chunk in chunks) {
        decoded.addAll(decoder.feed(chunk));
      }
      expect(decoded, hasLength(1));
      expect(decoded.first, equals(payload));
    });

    test('emits multiple complete frames when bytes arrive together', () {
      final p1 = Uint8List.fromList([1, 2, 3]);
      final p2 = Uint8List.fromList([10, 20, 30, 40]);
      final chunks1 = FrameEncoder.encode(p1, mtuPayloadSize: 100);
      final chunks2 = FrameEncoder.encode(p2, mtuPayloadSize: 100);
      final combined = Uint8List.fromList(
        chunks1.expand((c) => c).followedBy(chunks2.expand((c) => c)).toList(),
      );

      final decoder = FrameDecoder();
      final decoded = decoder.feed(combined);
      expect(decoded, hasLength(2));
      expect(decoded[0], equals(p1));
      expect(decoded[1], equals(p2));
    });

    test('emits no frame until the length prefix is complete', () {
      final decoder = FrameDecoder();
      // Only 2 bytes of the 4-byte length prefix.
      final partial = decoder.feed(Uint8List.fromList([0, 0]));
      expect(partial, isEmpty);
      // Two more length bytes + payload.
      final rest = decoder.feed(Uint8List.fromList([0, 3, 1, 2, 3]));
      expect(rest, hasLength(1));
      expect(rest.first, equals([1, 2, 3]));
    });

    test('rejects an oversize length prefix', () {
      final decoder = FrameDecoder();
      // 33 KB
      const tooBig = (32 * 1024) + 1;
      final view = ByteData(4)..setUint32(0, tooBig, Endian.big);
      expect(
        () => decoder.feed(view.buffer.asUint8List()),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
