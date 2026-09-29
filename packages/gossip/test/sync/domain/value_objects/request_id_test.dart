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
      // Each of these weighs three bytes, so 22 of them fit and 22 plus one
      // ASCII character does not — a character count would accept both.
      expect(RequestId('☃' * 21).value.length, equals(21));
      expect(() => RequestId('☃' * 22), throwsArgumentError);
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
