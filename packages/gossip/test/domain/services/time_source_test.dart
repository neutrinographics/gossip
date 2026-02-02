import 'package:test/test.dart';
import 'package:gossip/src/domain/services/time_source.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';

void main() {
  group('TimeSource', () {
    test('nowMillis delegates to TimePort.nowMs', () {
      final timerPort = InMemoryTimePort();
      final timeSource = TimeSource(timerPort);

      expect(timeSource.nowMillis(), equals(0));

      timerPort.advance(Duration(milliseconds: 100));

      expect(timeSource.nowMillis(), equals(100));
    });

    test('nowMillis tracks time advances', () async {
      final timerPort = InMemoryTimePort();
      final timeSource = TimeSource(timerPort);

      final time1 = timeSource.nowMillis();
      await timerPort.advance(Duration(milliseconds: 50));
      final time2 = timeSource.nowMillis();

      expect(time2, greaterThan(time1));
      expect(time2 - time1, equals(50));
    });
  });
}
