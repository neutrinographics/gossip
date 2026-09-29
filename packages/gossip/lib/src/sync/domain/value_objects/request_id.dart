import 'dart:convert';

/// The identity of one pull, minted by the node that issues it and
/// meaningless to anyone else: a peer echoes it back, so an arriving
/// response says which request it answers instead of leaving us to guess
/// from what it carries.
///
/// Opaque by contract. A responder compares it for equality and returns it
/// unchanged; nothing on either side may read structure into it, which is
/// what lets a requester change how it mints ids without any peer noticing.
///
/// An identifier like the node, channel and stream ids it travels beside,
/// under the same four-clause rule the Kotlin twin's `requireIdentifier`
/// applies to all of them: non-blank, well-formed Unicode, nothing JSON would
/// escape, and at most [maxIdentifierBytes]. A responder echoes whatever it
/// was sent, so an unbounded id would be an unbounded cost on every answer;
/// bounded, it is a cost each wire dialect subtracts from the entry payload it
/// can carry. One a peer sends outside the rule is a malformed frame, as any
/// other identifier would be.
class RequestId {
  /// The identifier bound, in UTF-8 bytes — what an echo can cost at most.
  static const int maxIdentifierBytes = 64;

  /// The identifier itself, as it travels on the wire.
  final String value;

  /// Creates a [RequestId] from [value].
  ///
  /// Throws [ArgumentError] when [value] is blank, is not well-formed Unicode,
  /// carries a character JSON escapes (a control character, a quote or a
  /// backslash — they cost more on the wire than they weigh), or exceeds
  /// [maxIdentifierBytes].
  RequestId(this.value) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(
        value,
        'value',
        'RequestId cannot be empty or whitespace',
      );
    }
    // A lone surrogate has no UTF-8 encoding: the encoder substitutes for it,
    // so two ids that differ here would reach the wire as one, weigh the same
    // and compare equal by bytes — an echo could then name the wrong request.
    if (!_isWellFormedUtf16(value)) {
      throw ArgumentError.value(
        value,
        'value',
        'RequestId must be well-formed Unicode (an unpaired surrogate has no '
            'UTF-8 encoding)',
      );
    }
    if (value.runes.any(
      (rune) => rune < 0x20 || rune == 0x22 || rune == 0x5C,
    )) {
      throw ArgumentError.value(
        value,
        'value',
        'RequestId must not contain control characters, quotes or backslashes',
      );
    }
    final bytes = utf8.encode(value).length;
    if (bytes > maxIdentifierBytes) {
      throw ArgumentError.value(
        value,
        'value',
        'RequestId must be at most $maxIdentifierBytes UTF-8 bytes, '
            'was $bytes',
      );
    }
  }

  /// An id unique among one requester's requests in flight: the issue
  /// instant, which separates requests across time, and a sequence the
  /// issuing value carries, which separates those of one instant. Base 36
  /// keeps it short on the wire, where it travels with every pull.
  ///
  /// Uniqueness is only ever claimed within one requester — a peer holds
  /// ours beside its own and answers each by the sender it came from — so
  /// nothing here has to be globally unique, and a restart may reuse an id
  /// whose request nobody is holding any more.
  factory RequestId.mint(int issuedAtMs, int sequence) => RequestId(
    '${issuedAtMs.toRadixString(36)}-${sequence.toRadixString(36)}',
  );

  @override
  bool operator ==(Object other) => other is RequestId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'RequestId($value)';
}

/// Whether every surrogate code unit in [value] is half of a proper pair.
bool _isWellFormedUtf16(String value) {
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    final isHigh = unit >= 0xD800 && unit <= 0xDBFF;
    final isLow = unit >= 0xDC00 && unit <= 0xDFFF;
    if (isLow) return false;
    if (isHigh) {
      if (i + 1 == value.length) return false;
      final next = value.codeUnitAt(i + 1);
      if (next < 0xDC00 || next > 0xDFFF) return false;
      i++;
    }
  }
  return true;
}
