import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';

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

    group('parse and tryParse', () {
      test('round-trip: toString then parse returns equal Hlc', () {
        final hlc = Hlc(1000, 5);
        final parsed = Hlc.parse(hlc.toString());
        expect(parsed, equals(hlc));
      });

      test('round-trip with zero values', () {
        final hlc = Hlc(0, 0);
        final parsed = Hlc.parse(hlc.toString());
        expect(parsed, equals(hlc));
      });

      test('round-trip with max logical value', () {
        final hlc = Hlc(999999999, 65535);
        final parsed = Hlc.parse(hlc.toString());
        expect(parsed, equals(hlc));
      });

      test('parse throws FormatException on empty string', () {
        expect(() => Hlc.parse(''), throwsA(isA<FormatException>()));
      });

      test('parse throws FormatException on malformed string', () {
        expect(() => Hlc.parse('not-an-hlc'), throwsA(isA<FormatException>()));
      });

      test('parse throws FormatException on missing prefix', () {
        expect(() => Hlc.parse('(1000:5)'), throwsA(isA<FormatException>()));
      });

      test('parse throws FormatException on missing logical', () {
        expect(() => Hlc.parse('Hlc(1000)'), throwsA(isA<FormatException>()));
      });

      test('parse throws FormatException on negative values', () {
        expect(() => Hlc.parse('Hlc(-1:0)'), throwsA(isA<FormatException>()));
      });

      test('tryParse returns Hlc on valid string', () {
        final hlc = Hlc.tryParse('Hlc(1000:5)');
        expect(hlc, equals(Hlc(1000, 5)));
      });

      test('tryParse returns null on malformed string', () {
        expect(Hlc.tryParse('garbage'), isNull);
      });

      test('tryParse returns null on empty string', () {
        expect(Hlc.tryParse(''), isNull);
      });
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

      test('constructor accepts maximum valid 48-bit physical value', () {
        final maxPhysical = (1 << 48) - 1;
        final hlc = Hlc(maxPhysical, 0);
        expect(hlc.physicalMs, equals(maxPhysical));
      });

      test(
        'constructor throws ArgumentError when physicalMs exceeds 48-bit max',
        () {
          // The documented wire/storage format packs physical time into 48
          // bits; an unbounded value would silently corrupt any packing
          // implementation (COR3-10).
          expect(() => Hlc(1 << 48, 0), throwsA(isA<ArgumentError>()));
        },
      );
    });
  });
}
