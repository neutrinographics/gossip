import 'package:test/test.dart';
import 'package:gossip/src/domain/services/hlc_clock.dart';
import 'package:gossip/src/domain/services/time_source.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';

/// Helper to create a TimeSource with controllable time for testing.
class TestTimeHelper {
  final InMemoryTimePort timePort;
  final TimeSource timeSource;

  TestTimeHelper._(this.timePort, this.timeSource);

  factory TestTimeHelper(int initialTimeMs) {
    final timerPort = InMemoryTimePort();
    // Advance to initial time
    if (initialTimeMs > 0) {
      timerPort.advance(Duration(milliseconds: initialTimeMs));
    }
    return TestTimeHelper._(timerPort, TimeSource(timerPort));
  }

  void advance(int ms) => timePort.advance(Duration(milliseconds: ms));
  void setTime(int ms) {
    final current = timePort.nowMs;
    if (ms > current) {
      timePort.advance(Duration(milliseconds: ms - current));
    }
  }
}

void main() {
  group('HlcClock', () {
    test('now() returns timestamp with current physical time', () {
      final helper = TestTimeHelper(1000);
      final clock = HlcClock(helper.timeSource);

      final result = clock.now();

      expect(result.physicalMs, equals(1000));
      expect(result.logical, equals(0));
    });

    test('now() increments logical when physical hasn\'t changed', () {
      final helper = TestTimeHelper(1000);
      final clock = HlcClock(helper.timeSource);

      final first = clock.now();
      final second = clock.now();
      final third = clock.now();

      expect(first.physicalMs, equals(1000));
      expect(first.logical, equals(0));
      expect(second.physicalMs, equals(1000));
      expect(second.logical, equals(1));
      expect(third.physicalMs, equals(1000));
      expect(third.logical, equals(2));
    });

    test('now() resets logical when physical advances', () {
      final helper = TestTimeHelper(1000);
      final clock = HlcClock(helper.timeSource);

      clock.now(); // physical=1000, logical=0
      clock.now(); // physical=1000, logical=1

      helper.setTime(2000);
      final result = clock.now();

      expect(result.physicalMs, equals(2000));
      expect(result.logical, equals(0));
    });

    test('now() handles logical overflow (>65535) by advancing physical', () {
      final helper = TestTimeHelper(1000);
      final clock = HlcClock(helper.timeSource);

      // Simulate hitting the overflow
      clock.restore(Hlc(1000, 65535));

      final result = clock.now();

      expect(result.physicalMs, equals(1001));
      expect(result.logical, equals(0));
    });

    test('receive() merges with remote timestamp', () {
      final helper = TestTimeHelper(1000);
      final clock = HlcClock(helper.timeSource);

      final remote = Hlc(2000, 5);
      final result = clock.receive(remote);

      expect(result.physicalMs, equals(2000));
      expect(result.logical, equals(6));
    });

    test('receive() takes max of physical times', () {
      final helper = TestTimeHelper(3000);
      final clock = HlcClock(helper.timeSource);

      // Remote is older
      final remote = Hlc(2000, 5);
      final result = clock.receive(remote);

      expect(result.physicalMs, equals(3000));
      expect(result.logical, equals(0));
    });

    test('receive() increments logical appropriately', () {
      final helper = TestTimeHelper(1000);
      final clock = HlcClock(helper.timeSource);

      // Generate local event first
      clock.now(); // physical=1000, logical=0

      // Receive remote with same physical, higher logical
      final remote = Hlc(1000, 5);
      final result = clock.receive(remote);

      expect(result.physicalMs, equals(1000));
      expect(result.logical, equals(6)); // max(0, 5) + 1
    });

    test('receive() handles overflow during merge', () {
      final helper = TestTimeHelper(1000);
      final clock = HlcClock(helper.timeSource);

      clock.restore(Hlc(1000, 10));

      final remote = Hlc(1000, 65535);
      final result = clock.receive(remote);

      expect(result.physicalMs, equals(1001));
      expect(result.logical, equals(0));
    });

    test('current returns last generated timestamp', () {
      final helper = TestTimeHelper(1000);
      final clock = HlcClock(helper.timeSource);

      clock.now();
      clock.now();
      final timestamp = clock.now();

      expect(clock.current, equals(timestamp));
    });

    test('restore() sets internal state from given Hlc', () {
      final helper = TestTimeHelper(1000);
      final clock = HlcClock(helper.timeSource);

      clock.restore(Hlc(5000, 42));

      expect(clock.current, equals(Hlc(5000, 42)));

      // Next now() should increment from restored state
      final result = clock.now();
      expect(result.physicalMs, equals(5000));
      expect(result.logical, equals(43));
    });
  });
}
