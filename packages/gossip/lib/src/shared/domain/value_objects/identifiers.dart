import 'dart:convert';

/// The rule every identifier that travels on the wire is held to, stated
/// once (the Kotlin twin's `requireIdentifier`).
///
/// Four clauses: non-blank; well-formed Unicode, because a lone surrogate has
/// no UTF-8 encoding and two values that differ only there would reach the
/// wire as one; nothing JSON would escape, so an identifier costs on the wire
/// exactly what it weighs; and at most [maxBytes] of UTF-8, so a value a peer
/// echoes back can never be an unbounded cost. The payload budget's envelope
/// allowance is only a true bound while every identifier in a frame obeys
/// all four. A value outside the rule is a malformed frame, as any other
/// malformed identifier field would be.
abstract final class Identifiers {
  static const int maxBytes = 64;

  /// Returns [value] when it satisfies the rule; throws [ArgumentError]
  /// naming [what] otherwise.
  static String require(String value, {required String what}) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(
        value,
        'value',
        '$what cannot be empty or whitespace',
      );
    }
    if (!_isWellFormedUtf16(value)) {
      throw ArgumentError.value(
        value,
        'value',
        '$what must be well-formed Unicode (an unpaired surrogate has no '
            'UTF-8 encoding)',
      );
    }
    if (value.runes.any(
      (rune) => rune < 0x20 || rune == 0x22 || rune == 0x5C,
    )) {
      throw ArgumentError.value(
        value,
        'value',
        '$what must not contain control characters, quotes or backslashes',
      );
    }
    final bytes = utf8.encode(value).length;
    if (bytes > maxBytes) {
      throw ArgumentError.value(
        value,
        'value',
        '$what must be at most $maxBytes UTF-8 bytes, was $bytes',
      );
    }
    return value;
  }

  /// Whether every surrogate code unit in [value] is half of a proper pair.
  static bool _isWellFormedUtf16(String value) {
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
}
