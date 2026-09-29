import 'package:gossip/src/shared/infrastructure/real_time_port.dart';
import 'package:test/test.dart';

void main() {
  group('RealTimePort', () {
    test('monotonicMs is a reading of its own, not the wall clock', () {
      final port = RealTimePort();

      // Seconds since this port was made, not milliseconds since the epoch:
      // a wall clock corrected while a wait is pending would otherwise make
      // that wait look already over, or longer than the timer knows it to be.
      expect(
        port.monotonicMs,
        lessThan(const Duration(minutes: 1).inMilliseconds),
      );
      expect(port.nowMs, greaterThan(DateTime(2020).millisecondsSinceEpoch));
    });

    test('monotonicMs moves with elapsed time', () async {
      final port = RealTimePort();

      await port.delay(const Duration(milliseconds: 20));

      expect(port.monotonicMs, greaterThanOrEqualTo(1));
    });
  });
}
