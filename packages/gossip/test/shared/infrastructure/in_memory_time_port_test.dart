// ignore_for_file: deprecated_member_use_from_same_package -- this file exercises tick()'s own contract, which advance() doesn't cover.
import 'package:test/test.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';

void main() {
  group('InMemoryTimePort', () {
    test('can schedule periodic callback', () {
      final timer = InMemoryTimePort();
      var callCount = 0;

      timer.schedulePeriodic(Duration(milliseconds: 100), () {
        callCount++;
      });

      expect(callCount, equals(0)); // Not called yet
    });

    test('callback fires when ticked', () {
      final timer = InMemoryTimePort();
      var callCount = 0;

      timer.schedulePeriodic(Duration(milliseconds: 100), () {
        callCount++;
      });

      timer.tick();

      expect(callCount, equals(1));
    });

    test('cancel via handle stops callbacks', () {
      final timer = InMemoryTimePort();
      var callCount = 0;

      final handle = timer.schedulePeriodic(Duration(milliseconds: 100), () {
        callCount++;
      });

      handle.cancel();
      timer.tick();

      expect(callCount, equals(0));
    });

    test('multiple ticks fire callback multiple times', () {
      final timer = InMemoryTimePort();
      var callCount = 0;

      timer.schedulePeriodic(Duration(milliseconds: 100), () {
        callCount++;
      });

      timer.tick();
      timer.tick();
      timer.tick();

      expect(callCount, equals(3));
    });

    test('multiple timers can be scheduled concurrently', () {
      final timer = InMemoryTimePort();
      var count1 = 0;
      var count2 = 0;

      timer.schedulePeriodic(Duration(milliseconds: 100), () {
        count1++;
      });

      timer.schedulePeriodic(Duration(milliseconds: 200), () {
        count2++;
      });

      timer.tick();

      expect(count1, equals(1));
      expect(count2, equals(1));
      expect(timer.activeTimerCount, equals(2));
    });

    test('cancelling one timer does not affect others', () {
      final timer = InMemoryTimePort();
      var count1 = 0;
      var count2 = 0;

      final handle1 = timer.schedulePeriodic(Duration(milliseconds: 100), () {
        count1++;
      });

      timer.schedulePeriodic(Duration(milliseconds: 200), () {
        count2++;
      });

      handle1.cancel();
      timer.tick();

      expect(count1, equals(0)); // Cancelled
      expect(count2, equals(1)); // Still active
      expect(timer.activeTimerCount, equals(1));
    });

    test('activeTimerCount tracks scheduled timers', () {
      final timer = InMemoryTimePort();

      expect(timer.activeTimerCount, equals(0));

      final handle1 = timer.schedulePeriodic(
        Duration(milliseconds: 100),
        () {},
      );
      expect(timer.activeTimerCount, equals(1));

      final handle2 = timer.schedulePeriodic(
        Duration(milliseconds: 100),
        () {},
      );
      expect(timer.activeTimerCount, equals(2));

      handle1.cancel();
      expect(timer.activeTimerCount, equals(1));

      handle2.cancel();
      expect(timer.activeTimerCount, equals(0));
    });

    group('schedulePeriodic rejects a non-positive-millisecond interval', () {
      test('throws ArgumentError for Duration.zero', () {
        final timer = InMemoryTimePort();

        expect(
          () => timer.schedulePeriodic(Duration.zero, () {}),
          throwsArgumentError,
        );
      });

      test(
        'throws ArgumentError for a sub-millisecond duration that '
        'truncates to zero (Duration(microseconds: 500).inMilliseconds == 0)',
        () {
          final timer = InMemoryTimePort();

          expect(
            () => timer.schedulePeriodic(
              const Duration(microseconds: 500),
              () {},
            ),
            throwsArgumentError,
          );
        },
      );
    });

    group("advance() honors each periodic timer's own interval", () {
      test(
        'advance(n × interval) fires the callback exactly n times',
        () async {
          final timer = InMemoryTimePort();
          var callCount = 0;

          timer.schedulePeriodic(Duration(milliseconds: 100), () {
            callCount++;
          });

          // n = 3: advancing by exactly three intervals must cross exactly
          // three firing boundaries — not one (the old tick()-per-advance()
          // behavior) and not some ticks-elapsed count unrelated to interval.
          await timer.advance(Duration(milliseconds: 300));

          expect(callCount, equals(3));
        },
      );

      test('advance(interval / 2) fires the callback zero times', () async {
        final timer = InMemoryTimePort();
        var callCount = 0;

        timer.schedulePeriodic(Duration(milliseconds: 100), () {
          callCount++;
        });

        await timer.advance(Duration(milliseconds: 50));

        expect(callCount, equals(0));
      });

      test(
        'sub-interval advances accumulate toward the next boundary',
        () async {
          final timer = InMemoryTimePort();
          var callCount = 0;

          timer.schedulePeriodic(Duration(milliseconds: 100), () {
            callCount++;
          });

          await timer.advance(Duration(milliseconds: 60));
          expect(callCount, equals(0));

          await timer.advance(Duration(milliseconds: 60));
          // Total elapsed is 120ms — one 100ms boundary crossed.
          expect(callCount, equals(1));
        },
      );

      test(
        'independent timers with different intervals fire independently under advance()',
        () async {
          final timer = InMemoryTimePort();
          var count100 = 0;
          var count250 = 0;

          timer.schedulePeriodic(Duration(milliseconds: 100), () {
            count100++;
          });
          timer.schedulePeriodic(Duration(milliseconds: 250), () {
            count250++;
          });

          await timer.advance(Duration(milliseconds: 500));

          expect(count100, equals(5));
          expect(count250, equals(2));
        },
      );

      test(
        'cancelling a timer stops it from firing on later advance()',
        () async {
          final timer = InMemoryTimePort();
          var callCount = 0;

          final handle = timer.schedulePeriodic(
            Duration(milliseconds: 100),
            () {
              callCount++;
            },
          );

          await timer.advance(Duration(milliseconds: 100));
          expect(callCount, equals(1));

          handle.cancel();
          await timer.advance(Duration(milliseconds: 300));
          expect(callCount, equals(1));
        },
      );
    });
  });
}
