import 'dart:typed_data';

/// Wire type-byte partition. Membership owns 0-2, sync owns 3-6. The
/// partition test asserts no overlap; changing an existing value is a
/// wire-format break and is forbidden.
abstract final class WireTypes {
  static const int ping = 0;
  static const int ack = 1;
  static const int pingReq = 2;
  static const int digestRequest = 3;
  static const int digestResponse = 4;
  static const int deltaRequest = 5;
  static const int deltaResponse = 6;

  static const Set<int> membership = {ping, ack, pingReq};
  static const Set<int> sync = {
    digestRequest,
    digestResponse,
    deltaRequest,
    deltaResponse,
  };

  /// Union of every type byte owned by any current bounded context.
  ///
  /// Lets a per-context codec's `decode` distinguish a genuinely unknown
  /// (corrupt) type byte — outside [known] entirely — from a byte that
  /// belongs to a sibling context's family (in [known], just not this
  /// codec's own set): the former must throw (malformed frame), the latter
  /// must answer null ("not mine", routine traffic to ignore). Referencing
  /// this shared constant is not a context-to-context dependency — it's the
  /// same envelope-partition agreement both families already publish here.
  static const Set<int> known = {...membership, ...sync};

  /// First byte of every v2 frame. Marker bytes encode the version
  /// directly: version = byte - 0xF0. 0xF0/0xF1 are permanently
  /// unassigned (v0 does not exist; v1 is *defined* as the unprefixed
  /// form), 0xF3-0xFE are unregistered until a version claims them, and
  /// 0xFF is reserved as an escape for a future extended-version form.
  static const int markerV2 = 0xF2;

  /// Classifies a frame's leading byte(s) and returns the index of the
  /// type byte: 0 for a v1 frame, 1 for a registered-marker frame.
  ///
  /// Owning this here keeps marker-range knowledge in the same shared
  /// envelope agreement that owns the type-byte partition: the codec
  /// facades never read marker semantics themselves. Throws
  /// [ArgumentError] for anything undecodable by every codec — empty
  /// frames, reserved bytes, unassigned markers, the escape byte, or a
  /// marker with no type byte after it.
  static int frameTypeOffset(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw ArgumentError('Cannot decode empty bytes');
    }
    final first = bytes[0];
    if (known.contains(first)) return 0;
    if (first == markerV2) {
      if (bytes.length < 2) {
        throw ArgumentError('Version marker with no type byte');
      }
      return 1;
    }
    throw ArgumentError('Unknown message type: $first');
  }
}
