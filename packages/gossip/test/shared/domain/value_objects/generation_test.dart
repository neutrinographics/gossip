import 'package:gossip/src/shared/domain/value_objects/generation.dart';
import 'package:test/test.dart';

void main() {
  group('Generation', () {
    test('the initial value has a closed gate and no wait pending', () {
      expect(Generation.initial.number, equals(0));
      expect(Generation.initial.running, isFalse);
      expect(Generation.initial.waitEndsAtMs, isNull);
    });

    test('two generations are equal exactly when all three parts match', () {
      // Built without `const` on purpose: two const expressions would be the
      // same canonical instance, and the hand-written == would never be asked.
      final armed = Generation(number: 3, running: true, waitEndsAtMs: 30000);

      expect(
        armed,
        equals(Generation(number: 3, running: true, waitEndsAtMs: 30000)),
      );
      expect(
        armed,
        isNot(
          equals(Generation(number: 4, running: true, waitEndsAtMs: 30000)),
        ),
        reason: 'a different number is a different run',
      );
      expect(
        armed,
        isNot(
          equals(Generation(number: 3, running: false, waitEndsAtMs: 30000)),
        ),
        reason: 'the gate is part of the value',
      );
      expect(
        armed,
        isNot(equals(Generation(number: 3, running: true))),
        reason: 'a pending wait is not the same state as no wait pending',
      );
    });

    test('equal generations hash alike', () {
      expect(
        Generation(number: 3, running: true, waitEndsAtMs: 30000).hashCode,
        equals(
          Generation(number: 3, running: true, waitEndsAtMs: 30000).hashCode,
        ),
      );
    });

    test('toString names all three parts', () {
      final rendered = Generation(
        number: 3,
        running: true,
        waitEndsAtMs: 30000,
      ).toString();

      expect(rendered, contains('3'));
      expect(rendered, contains('true'));
      expect(rendered, contains('30000'));
    });
  });
}
