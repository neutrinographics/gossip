import 'dart:math';

import 'package:gossip/src/shared/domain/services/jitter.dart';
import 'package:test/test.dart';

/// Scheduler intervals get ±fraction uniform jitter so self-scheduling
/// timer loops don't phase-lock across nodes.
void main() {
  group('applyJitter', () {
    test('stays within +/-20% of the base by default', () {
      final rng = Random(7);
      const base = Duration(seconds: 1);
      final lo = (base.inMicroseconds * 0.8).round();
      final hi = (base.inMicroseconds * 1.2).round();

      for (var i = 0; i < 2000; i++) {
        final jittered = applyJitter(base, rng);
        expect(jittered.inMicroseconds, greaterThanOrEqualTo(lo));
        expect(jittered.inMicroseconds, lessThanOrEqualTo(hi));
      }
    });

    test('actually varies (does not return a constant)', () {
      final rng = Random(7);
      const base = Duration(seconds: 1);
      final samples = {
        for (var i = 0; i < 50; i++) applyJitter(base, rng).inMicroseconds,
      };
      expect(samples.length, greaterThan(1));
    });

    test('respects a custom fraction', () {
      final rng = Random(7);
      const base = Duration(milliseconds: 1000);
      final lo = (base.inMicroseconds * 0.9).round();
      final hi = (base.inMicroseconds * 1.1).round();

      for (var i = 0; i < 2000; i++) {
        final jittered = applyJitter(base, rng, fraction: 0.1);
        expect(jittered.inMicroseconds, greaterThanOrEqualTo(lo));
        expect(jittered.inMicroseconds, lessThanOrEqualTo(hi));
      }
    });

    test('zero fraction is a no-op', () {
      final rng = Random(7);
      const base = Duration(seconds: 3);
      expect(applyJitter(base, rng, fraction: 0), equals(base));
    });
  });
}
