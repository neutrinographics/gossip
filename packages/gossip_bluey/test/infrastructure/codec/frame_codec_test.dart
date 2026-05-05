import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/infrastructure/codec/frame_codec.dart';

void main() {
  group('FrameEncoder', () {
    // Magic 0x47535031 == ASCII "GSP1"
    const magic = [0x47, 0x53, 0x50, 0x31];

    test('emits a single chunk when payload + magic + length fits the MTU', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 100);
      expect(chunks, hasLength(1));
      expect(chunks.first, hasLength(8 + 5));
      // magic
      expect(chunks.first.sublist(0, 4), equals(magic));
      // length prefix: big-endian 5
      expect(chunks.first.sublist(4, 8), equals([0, 0, 0, 5]));
      // payload
      expect(chunks.first.sublist(8), equals([1, 2, 3, 4, 5]));
    });

    test('splits across multiple chunks when payload exceeds MTU', () {
      // mtuPayloadSize = 12. Magic + length prefix take 8 bytes of the
      // first chunk. Payload = 20 bytes. First chunk carries 8 header
      // bytes + 4 payload bytes; remaining 16 payload bytes need
      // ceil(16/12) = 2 chunks.
      final payload = Uint8List.fromList(List.generate(20, (i) => i));
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 12);
      expect(chunks, hasLength(3));
      expect(chunks[0], hasLength(12));
      expect(chunks[0].sublist(0, 4), equals(magic));
      expect(chunks[0].sublist(4, 8), equals([0, 0, 0, 20]));
      expect(chunks[0].sublist(8), equals([0, 1, 2, 3]));
      expect(chunks[1], hasLength(12));
      expect(chunks[1], equals([4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]));
      expect(chunks[2], hasLength(4));
      expect(chunks[2], equals([16, 17, 18, 19]));
    });

    test('throws on empty payload', () {
      expect(
        () => FrameEncoder.encode(Uint8List(0), mtuPayloadSize: 20),
        throwsArgumentError,
      );
    });

    test('throws when mtuPayloadSize is too small to hold magic + length', () {
      // magic + length = 8 bytes; need at least one byte of payload room
      // in the first chunk.
      expect(
        () => FrameEncoder.encode(Uint8List.fromList([1]), mtuPayloadSize: 8),
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
    const magic = [0x47, 0x53, 0x50, 0x31];

    /// Helper: build a single complete frame on the wire.
    Uint8List frame(List<int> payload) {
      final out = BytesBuilder()
        ..add(magic)
        ..add([
          (payload.length >> 24) & 0xFF,
          (payload.length >> 16) & 0xFF,
          (payload.length >> 8) & 0xFF,
          payload.length & 0xFF,
        ])
        ..add(payload);
      return out.toBytes();
    }

    test('happy path: a single complete frame is emitted', () {
      final dec = FrameDecoder();
      final result = dec.feed(frame([1, 2, 3, 4, 5]));
      expect(result.messages, hasLength(1));
      expect(result.messages.first, equals([1, 2, 3, 4, 5]));
      expect(result.bytesDiscarded, equals(0));
    });

    test('multiple frames in one chunk are all emitted', () {
      final dec = FrameDecoder();
      final combined = BytesBuilder()
        ..add(frame([1, 2, 3]))
        ..add(frame([4, 5, 6, 7]));
      final result = dec.feed(combined.toBytes());
      expect(result.messages, hasLength(2));
      expect(result.messages[0], equals([1, 2, 3]));
      expect(result.messages[1], equals([4, 5, 6, 7]));
      expect(result.bytesDiscarded, equals(0));
    });

    test('frame split across chunks emits once both have arrived', () {
      final dec = FrameDecoder();
      final whole = frame([10, 20, 30, 40]);
      // split somewhere in the middle of the payload
      final r1 = dec.feed(whole.sublist(0, 9));
      final r2 = dec.feed(whole.sublist(9));
      expect(r1.messages, isEmpty);
      expect(r2.messages, hasLength(1));
      expect(r2.messages.first, equals([10, 20, 30, 40]));
      expect(r1.bytesDiscarded, equals(0));
      expect(r2.bytesDiscarded, equals(0));
    });

    test('garbage prefix is discarded; subsequent frame is emitted', () {
      final dec = FrameDecoder();
      final input = BytesBuilder()
        ..add([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11]) // 7 garbage bytes
        ..add(frame([1, 2, 3]));
      final result = dec.feed(input.toBytes());
      expect(result.messages, hasLength(1));
      expect(result.messages.first, equals([1, 2, 3]));
      expect(result.bytesDiscarded, equals(7));
    });

    test(
      'corruption mid-stream eventually re-syncs to the next valid magic',
      () {
        // Realistic BLE-drop scenario: a chunk is lost mid-payload, so the
        // decoder reads frame A's plausible length value, consumes some
        // bytes from frame B (corrupting both), and may emit a bogus
        // payload. The decoder must then re-sync on a *subsequent* valid
        // magic — frame C — and emit C correctly without throwing or
        // hanging. We accept the in-flight bogus message as the cost of
        // length-prefix corruption that produces a plausible length;
        // recovery is "connection survives, future frames decode."
        final dec = FrameDecoder();
        // A: 12-byte frame, truncated by 5 bytes of its payload.
        final a = frame([
          0xAA,
          0xAA,
          0xAA,
          0xAA,
          0xAA,
          0xAA,
          0xAA,
          0xAA,
          0xAA,
          0xAA,
        ]);
        final aTruncated = a.sublist(0, a.length - 5);
        final b = frame([0xBB, 0xBB, 0xBB]);
        final c = frame([1, 2, 3]);
        final input = BytesBuilder()
          ..add(aTruncated)
          ..add(b)
          ..add(c);
        final result = dec.feed(input.toBytes());

        // C must be emitted correctly.
        expect(result.messages, isNotEmpty);
        expect(result.messages.last, equals([1, 2, 3]));
        // Recovery did some byte-discarding while seeking C's magic.
        expect(result.bytesDiscarded, greaterThan(0));
      },
    );

    test('implausible length triggers re-scan, not exception', () {
      final dec = FrameDecoder();
      // A frame whose length field claims 0xFFFFFFFF bytes — impossible,
      // exceeds kMaxFramePayload. Decoder must reject and re-scan.
      final bogus = Uint8List.fromList([...magic, 0xFF, 0xFF, 0xFF, 0xFF]);
      final good = frame([42]);
      final combined = BytesBuilder()
        ..add(bogus)
        ..add(good);
      final result = dec.feed(combined.toBytes());
      expect(result.messages, hasLength(1));
      expect(result.messages.first, equals([42]));
      expect(result.bytesDiscarded, greaterThan(0));
    });

    test('partial magic across chunks does not falsely match', () {
      final dec = FrameDecoder();
      // First chunk: only the first two bytes of the magic.
      final r1 = dec.feed(Uint8List.fromList([0x47, 0x53]));
      // Second chunk: the rest of the magic + length + payload.
      final r2 = dec.feed(
        Uint8List.fromList([
          0x50,
          0x31,
          0x00,
          0x00,
          0x00,
          0x03,
          0x77,
          0x88,
          0x99,
        ]),
      );
      expect(r1.messages, isEmpty);
      expect(r1.bytesDiscarded, equals(0));
      expect(r2.messages, hasLength(1));
      expect(r2.messages.first, equals([0x77, 0x88, 0x99]));
      expect(r2.bytesDiscarded, equals(0));
    });

    test('bounded buffer prevents unbounded growth on garbage stream', () {
      final dec = FrameDecoder();
      // Feed 100 KB of garbage that doesn't contain the magic anywhere.
      // Use a byte that isn't part of magic to avoid accidental matches.
      final garbage = Uint8List(100 * 1024)..fillRange(0, 100 * 1024, 0x55);
      final result = dec.feed(garbage);
      expect(result.messages, isEmpty);
      // bytesDiscarded should reflect that the decoder dropped old bytes
      // when the buffer cap was hit. We just assert it's non-trivially
      // large — proving the decoder isn't accumulating the full 100 KB.
      expect(result.bytesDiscarded, greaterThanOrEqualTo(32 * 1024));
    });
  });
}
