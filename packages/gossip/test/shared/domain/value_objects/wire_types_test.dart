import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_types.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';

void main() {
  test('the type-byte partition has no overlaps and covers 0-6', () {
    expect(WireTypes.membership.intersection(WireTypes.sync), isEmpty);
    expect(WireTypes.membership.union(WireTypes.sync), {0, 1, 2, 3, 4, 5, 6});
  });

  test('known is exactly the union of every context family', () {
    expect(WireTypes.known, equals(WireTypes.membership.union(WireTypes.sync)));
  });

  group('version marker table', () {
    test('0xF2 is the v2 marker and markers do not collide with type bytes', () {
      expect(WireTypes.markerV2, equals(0xF2));
      expect(WireTypes.known.contains(WireTypes.markerV2), isFalse);
    });

    test('frameTypeOffset is 0 for v1 frames and 1 for v2 frames', () {
      expect(WireTypes.frameTypeOffset(Uint8List.fromList([3, 123])), equals(0));
      expect(
        WireTypes.frameTypeOffset(Uint8List.fromList([0xF2, 3, 123])),
        equals(1),
      );
    });

    test('empty, reserved, unassigned-marker and escape bytes all throw', () {
      for (final frame in [
        <int>[],
        [0x07], [0x80], [0xEF],      // reserved gap
        [0xF0, 3], [0xF1, 3],        // permanently unassigned markers
        [0xF3, 3], [0xFE, 3],        // unregistered versions
        [0xFF, 3],                   // escape byte
        [0xF2],                      // marker with nothing after it
      ]) {
        expect(
          () => WireTypes.frameTypeOffset(Uint8List.fromList(frame)),
          throwsArgumentError,
          reason: 'frame $frame',
        );
      }
    });

    test('WireVersion has exactly v1 and v2', () {
      expect(WireVersion.values, [WireVersion.v1, WireVersion.v2]);
    });
  });
}
