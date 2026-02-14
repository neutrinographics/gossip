import 'package:gossip/src/facade/coordinator_config.dart';
import 'package:test/test.dart';

void main() {
  group('CoordinatorConfig', () {
    test('defaults has expected values', () {
      final config = CoordinatorConfig.defaults;

      expect(config.suspicionThreshold, equals(5));
      expect(config.unreachableThreshold, equals(15));
      expect(config.startupGracePeriod, equals(const Duration(seconds: 10)));
    });

    test('can be created with custom values', () {
      final config = CoordinatorConfig(
        suspicionThreshold: 3,
        unreachableThreshold: 10,
        startupGracePeriod: const Duration(seconds: 5),
      );

      expect(config.suspicionThreshold, equals(3));
      expect(config.unreachableThreshold, equals(10));
      expect(config.startupGracePeriod, equals(const Duration(seconds: 5)));
    });

    test('startupGracePeriod can be disabled with Duration.zero', () {
      final config = CoordinatorConfig(startupGracePeriod: Duration.zero);

      expect(config.startupGracePeriod, equals(Duration.zero));
    });
  });
}
