import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/services/time_source.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';

void main() {
  group('TimeSource', () {
    test('nowMillis delegates to TimePort.nowMs', () {
      final timePort = InMemoryTimePort();
      final timeSource = TimeSource(timePort);

      expect(timeSource.nowMillis(), equals(0));

      timePort.advance(Duration(milliseconds: 100));

      expect(timeSource.nowMillis(), equals(100));
    });

    test('nowMillis tracks time advances', () async {
      final timePort = InMemoryTimePort();
      final timeSource = TimeSource(timePort);

      final time1 = timeSource.nowMillis();
      await timePort.advance(Duration(milliseconds: 50));
      final time2 = timeSource.nowMillis();

      expect(time2, greaterThan(time1));
      expect(time2 - time1, equals(50));
    });
  });
}
