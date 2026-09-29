import 'package:gossip/src/sync/domain/value_objects/request_id.dart';
import 'package:test/test.dart';

/// The identity a requester mints for one pull. Opaque by contract, so
/// nothing here reads structure into a minted id beyond its uniqueness.
void main() {
  group('mint', () {
    test('ids minted from different instants or sequences differ', () {
      expect(RequestId.mint(1, 0), isNot(equals(RequestId.mint(0, 1))));
      expect(RequestId.mint(0, 0), isNot(equals(RequestId.mint(0, 1))));
      expect(RequestId.mint(0, 0), isNot(equals(RequestId.mint(1, 0))));
    });

    test('the same reading and sequence name the same request', () {
      expect(RequestId.mint(7, 3), equals(RequestId.mint(7, 3)));
      expect(
        RequestId.mint(7, 3).hashCode,
        equals(RequestId.mint(7, 3).hashCode),
      );
    });

    test('a minted id is far inside the identifier bound', () {
      final extreme = RequestId.mint(
        0x7FFFFFFFFFFFFFFF,
        0x7FFFFFFFFFFFFFFF,
      ).value;

      expect(extreme.length, lessThan(RequestId.maxIdentifierBytes));
    });
  });

  group('the identifier rule', () {
    test('an id at the byte bound is accepted, one past it is refused', () {
      expect(
        RequestId('z' * RequestId.maxIdentifierBytes).value.length,
        equals(RequestId.maxIdentifierBytes),
      );
      expect(
        () => RequestId('z' * (RequestId.maxIdentifierBytes + 1)),
        throwsArgumentError,
      );
    });

    test('the bound is UTF-8 bytes, not characters', () {
      // Each of these weighs three bytes, so 21 of them fit (63 bytes) and 22
      // do not (66) — a character count would accept both, being far under 64.
      expect(RequestId('☃' * 21).value.length, equals(21));
      expect(() => RequestId('☃' * 22), throwsArgumentError);
    });

    test('an id that is not well-formed Unicode is refused', () {
      // A lone surrogate has no UTF-8 encoding: the encoder substitutes for
      // it, so two ids differing only there would reach the wire as one.
      expect(
        () => RequestId('req-${String.fromCharCode(0xD83D)}'),
        throwsArgumentError,
      );
      expect(
        () => RequestId('req-${String.fromCharCode(0xDE00)}'),
        throwsArgumentError,
      );
      expect(
        RequestId('req-${String.fromCharCodes([0xD83D, 0xDE00])}').value.length,
        equals(6),
        reason: 'a proper surrogate pair is one character and is accepted',
      );
    });

    test('an id JSON would escape is refused', () {
      expect(() => RequestId('with"quote'), throwsArgumentError);
      expect(() => RequestId('with\\backslash'), throwsArgumentError);
      expect(() => RequestId('with\nnewline'), throwsArgumentError);
    });

    test('a blank id is refused', () {
      expect(() => RequestId(''), throwsArgumentError);
      expect(() => RequestId('   '), throwsArgumentError);
    });
  });

  test('equality is the value, whoever minted it', () {
    expect(RequestId('abc'), equals(RequestId('abc')));
    expect(RequestId('abc').hashCode, equals(RequestId('abc').hashCode));
    expect(RequestId('abc'), isNot(equals(RequestId('abd'))));
  });
}
