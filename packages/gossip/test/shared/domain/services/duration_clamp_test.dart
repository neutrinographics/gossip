import 'package:gossip/src/shared/domain/services/duration_clamp.dart';
import 'package:test/test.dart';

/// One clamp for the whole library: the codebase had three hand-rolled
/// styles for the same "keep a Duration inside [min, max]" operation.
void main() {
  group('clampDuration', () {
    const min = Duration(milliseconds: 50);
    const max = Duration(seconds: 30);

    test('below min returns min', () {
      final result = clampDuration(
        const Duration(milliseconds: 10),
        min: min,
        max: max,
      );
      expect(result, equals(min));
    });

    test('above max returns max', () {
      final result = clampDuration(
        const Duration(seconds: 60),
        min: min,
        max: max,
      );
      expect(result, equals(max));
    });

    test('in range returns value unchanged', () {
      const value = Duration(seconds: 1);
      final result = clampDuration(value, min: min, max: max);
      expect(result, equals(value));
    });

    test('value exactly at the min bound returns that bound', () {
      final result = clampDuration(min, min: min, max: max);
      expect(result, equals(min));
    });

    test('value exactly at the max bound returns that bound', () {
      final result = clampDuration(max, min: min, max: max);
      expect(result, equals(max));
    });
  });
}
