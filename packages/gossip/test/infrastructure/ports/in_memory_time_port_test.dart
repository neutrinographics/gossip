import 'package:test/test.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';

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
  });
}
