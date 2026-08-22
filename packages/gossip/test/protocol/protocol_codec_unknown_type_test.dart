import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';

/// Pins `ProtocolCodec`'s current unknown-type-byte and malformed-frame
/// behavior BEFORE the codec is split into per-context codecs (see the
/// bounded-contexts-restructure Task 2 brief). The controller ruling requires
/// the post-split composite to raise exactly these errors when both context
/// codecs answer "not mine" — this test is the regression proof.
void main() {
  group('ProtocolCodec unknown-type behavior (pre-split baseline)', () {
    test('decode throws ArgumentError for a type byte outside 0-6', () {
      final codec = ProtocolCodec();
      final bytes = Uint8List.fromList([99, ...'{}'.codeUnits]);

      expect(
        () => codec.decode(bytes),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'Unknown message type: 99',
          ),
        ),
      );
    });

    test('decode throws ArgumentError for empty bytes', () {
      final codec = ProtocolCodec();

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
  });
}
