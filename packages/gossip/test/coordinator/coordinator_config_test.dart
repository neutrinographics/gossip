import 'package:gossip/src/coordinator/coordinator_config.dart';
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

    test('announceBudgetBytes defaults to 1024', () {
      expect(CoordinatorConfig.defaults.announceBudgetBytes, equals(1024));
    });

    test('announceBudgetBytes of zero is accepted (never announces)', () {
      final config = CoordinatorConfig(announceBudgetBytes: 0);

      expect(config.announceBudgetBytes, equals(0));
    });

    test('announceBudgetBytes rejects a negative budget', () {
      expect(
        () => CoordinatorConfig(announceBudgetBytes: -1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('hlcMaxDrift defaults to one hour and is overridable', () {
      expect(
        CoordinatorConfig.defaults.hlcMaxDrift,
        equals(const Duration(hours: 1)),
      );

      final config = CoordinatorConfig(hlcMaxDrift: const Duration(minutes: 5));
      expect(config.hlcMaxDrift, equals(const Duration(minutes: 5)));
    });
  });
}
