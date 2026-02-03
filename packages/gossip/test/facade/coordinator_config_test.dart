import 'package:gossip/src/facade/coordinator_config.dart';
import 'package:test/test.dart';

void main() {
  group('CoordinatorConfig', () {
    test('defaults has expected values', () {
      final config = CoordinatorConfig.defaults;

      expect(config.gossipInterval, equals(const Duration(milliseconds: 500)));
      expect(config.suspicionThreshold, equals(5));
    });

    test('can be created with custom values', () {
      final config = CoordinatorConfig(
        gossipInterval: const Duration(milliseconds: 100),
        suspicionThreshold: 3,
      );

      expect(config.gossipInterval, equals(const Duration(milliseconds: 100)));
      expect(config.suspicionThreshold, equals(3));
    });

    test('partial custom values use defaults for others', () {
      final config = CoordinatorConfig(
        gossipInterval: const Duration(milliseconds: 50),
      );

      expect(config.gossipInterval, equals(const Duration(milliseconds: 50)));
      // suspicionThreshold should be default
      expect(config.suspicionThreshold, equals(5));
    });
  });
}
