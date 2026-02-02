import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';

void main() {
  group('Hlc', () {
    test('two Hlcs with same physical and logical are equal', () {
      final hlc1 = Hlc(1000, 5);
      final hlc2 = Hlc(1000, 5);

      expect(hlc1, equals(hlc2));
    });

    test('Hlc with greater physicalMs is greater', () {
      final hlc1 = Hlc(1000, 5);
      final hlc2 = Hlc(2000, 3);

      expect(hlc2.compareTo(hlc1), greaterThan(0));
      expect(hlc1.compareTo(hlc2), lessThan(0));
    });

    test('Hlc with same physicalMs but greater logical is greater', () {
      final hlc1 = Hlc(1000, 5);
      final hlc2 = Hlc(1000, 10);

      expect(hlc2.compareTo(hlc1), greaterThan(0));
      expect(hlc1.compareTo(hlc2), lessThan(0));
    });

    test('compareTo returns correct ordering', () {
      final hlc1 = Hlc(1000, 5);
      final hlc2 = Hlc(1000, 5);

      expect(hlc1.compareTo(hlc2), equals(0));
    });

    test('comparison operators work correctly', () {
      final hlc1 = Hlc(1000, 5);
      final hlc2 = Hlc(2000, 3);
      final hlc3 = Hlc(1000, 5);

      expect(hlc1 < hlc2, isTrue);
      expect(hlc2 > hlc1, isTrue);
      expect(hlc1 <= hlc3, isTrue);
      expect(hlc1 >= hlc3, isTrue);
      expect(hlc2 >= hlc1, isTrue);
    });

    test('subtract returns Hlc with reduced physicalMs and zero logical', () {
      final hlc = Hlc(5000, 10);
      final result = hlc.subtract(Duration(milliseconds: 2000));

      expect(result, equals(Hlc(3000, 0)));
    });

    test('Hlc.zero is (0, 0)', () {
      expect(Hlc.zero, equals(Hlc(0, 0)));
    });

    test('hashCode is consistent with equality', () {
      final hlc1 = Hlc(1000, 5);
      final hlc2 = Hlc(1000, 5);
      final hlc3 = Hlc(1000, 6);

      expect(hlc1.hashCode, equals(hlc2.hashCode));
      expect(hlc1.hashCode, isNot(equals(hlc3.hashCode)));
    });

    group('invariant validation', () {
      test('constructor throws ArgumentError when physicalMs is negative', () {
        expect(() => Hlc(-1, 0), throwsA(isA<ArgumentError>()));
      });

      test('constructor throws ArgumentError when logical is negative', () {
        expect(() => Hlc(1000, -1), throwsA(isA<ArgumentError>()));
      });

      test(
        'constructor throws ArgumentError when logical exceeds 16-bit max',
        () {
          expect(() => Hlc(1000, 65536), throwsA(isA<ArgumentError>()));
        },
      );

      test('constructor accepts maximum valid 16-bit logical value', () {
        final hlc = Hlc(1000, 65535);
        expect(hlc.logical, equals(65535));
      });

      test('constructor accepts zero for both values', () {
        final hlc = Hlc(0, 0);
        expect(hlc.physicalMs, equals(0));
        expect(hlc.logical, equals(0));
      });
    });
  });
}
