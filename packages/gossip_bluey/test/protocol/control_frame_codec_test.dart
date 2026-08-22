import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/protocol/control_frame_codec.dart';
import 'package:gossip_bluey/src/protocol/frame_codec.dart';

void main() {
  group('ControlFrameCodec', () {
    test('encodeRejection produces GSP2 magic, length, type, reason', () {
      final bytes = ControlFrameCodec.encodeRejection(RejectionReason.capacity);

      // "GSP2" + u32 BE length (2: type + reason) + type 0x01 + reason 0x01
      expect(
        bytes,
        equals([0x47, 0x53, 0x50, 0x32, 0, 0, 0, 2, 0x01, 0x01]),
      );
    });

    test('tryParse round-trips a rejection frame', () {
      final bytes = ControlFrameCodec.encodeRejection(RejectionReason.capacity);
      final frame = ControlFrameCodec.tryParse(bytes);

      expect(frame, isA<ConnectionRejectedFrame>());
      expect(
        (frame! as ConnectionRejectedFrame).reason,
        RejectionReason.capacity,
      );
    });

    test('tryParse returns null for GSP1 data frames', () {
      final chunks = FrameEncoder.encode(
        Uint8List.fromList([1, 2, 3]),
        mtuPayloadSize: 200,
      );
      expect(ControlFrameCodec.tryParse(chunks.single), isNull);
    });

    test('tryParse returns null for truncated, oversized, or trailing-garbage input', () {
      final good = ControlFrameCodec.encodeRejection(RejectionReason.capacity);
      expect(ControlFrameCodec.tryParse(Uint8List.sublistView(good, 0, 9)), isNull,
          reason: 'truncated');
      expect(
        ControlFrameCodec.tryParse(Uint8List.fromList([...good, 0xFF])),
        isNull,
        reason: 'declared length must match exactly — trailing bytes mean '
            'this is not a lone control frame',
      );
      expect(ControlFrameCodec.tryParse(Uint8List(0)), isNull, reason: 'empty');
    });

    test('tryParse returns null for unknown type or reason bytes', () {
      // Unknown type 0x7F.
      expect(
        ControlFrameCodec.tryParse(
          Uint8List.fromList([0x47, 0x53, 0x50, 0x32, 0, 0, 0, 2, 0x7F, 0x01]),
        ),
        isNull,
      );
      // Known type, unknown reason 0x7F.
      expect(
        ControlFrameCodec.tryParse(
          Uint8List.fromList([0x47, 0x53, 0x50, 0x32, 0, 0, 0, 2, 0x01, 0x7F]),
        ),
        isNull,
      );
    });

    test('a GSP1 decoder skips a GSP2 frame via garbage recovery and still '
        'decodes a following GSP1 frame (mixed-version safety)', () {
      final decoder = FrameDecoder();
      final rejection = ControlFrameCodec.encodeRejection(RejectionReason.capacity);
      final payload = Uint8List.fromList([9, 8, 7]);
      final dataFrame = FrameEncoder.encode(payload, mtuPayloadSize: 200).single;

      final result = decoder.feed(Uint8List.fromList([...rejection, ...dataFrame]));

      expect(result.messages, hasLength(1));
      expect(result.messages.single, equals(payload));
      expect(result.bytesDiscarded, greaterThan(0),
          reason: 'the GSP2 bytes must be counted as discarded garbage');
    });
  });

  group('FrameDecoder.isAtFrameBoundary', () {
    test('true when idle, false mid-frame, true again after completion', () {
      final decoder = FrameDecoder();
      expect(decoder.isAtFrameBoundary, isTrue);

      final payload = Uint8List.fromList(List.filled(50, 42));
      final chunks = FrameEncoder.encode(payload, mtuPayloadSize: 20);
      decoder.feed(chunks.first);
      expect(decoder.isAtFrameBoundary, isFalse);

      for (final c in chunks.skip(1)) {
        decoder.feed(c);
      }
      expect(decoder.isAtFrameBoundary, isTrue);
    });
  });
}
