import 'package:gossip/src/facade/coordinator_config.dart';
import 'package:test/test.dart';

void main() {
  group('CoordinatorConfig', () {
    test('defaults has expected values', () {
      final config = CoordinatorConfig.defaults;

      expect(config.suspicionThreshold, equals(5));
    });

    test('can be created with custom values', () {
      final config = CoordinatorConfig(suspicionThreshold: 3);

      expect(config.suspicionThreshold, equals(3));
    });
  });
}
