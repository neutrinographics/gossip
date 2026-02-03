import 'package:gossip/src/facade/coordinator_config.dart';
import 'package:test/test.dart';

void main() {
  group('CoordinatorConfig', () {
    test('defaults has expected values', () {
      final config = CoordinatorConfig.defaults;

      expect(config.gossipInterval, equals(const Duration(milliseconds: 500)));
      expect(config.probeInterval, equals(const Duration(milliseconds: 3000)));
      expect(config.pingTimeout, equals(const Duration(milliseconds: 2000)));
      expect(
        config.indirectPingTimeout,
        equals(const Duration(milliseconds: 2000)),
      );
      expect(config.suspicionThreshold, equals(5));
    });

    test('can be created with custom values', () {
      final config = CoordinatorConfig(
        gossipInterval: const Duration(milliseconds: 100),
        probeInterval: const Duration(milliseconds: 500),
        pingTimeout: const Duration(milliseconds: 250),
        indirectPingTimeout: const Duration(milliseconds: 300),
        suspicionThreshold: 5,
      );

      expect(config.gossipInterval, equals(const Duration(milliseconds: 100)));
      expect(config.probeInterval, equals(const Duration(milliseconds: 500)));
      expect(config.pingTimeout, equals(const Duration(milliseconds: 250)));
      expect(
        config.indirectPingTimeout,
        equals(const Duration(milliseconds: 300)),
      );
      expect(config.suspicionThreshold, equals(5));
    });

    test('partial custom values use defaults for others', () {
      final config = CoordinatorConfig(
        gossipInterval: const Duration(milliseconds: 50),
      );

      expect(config.gossipInterval, equals(const Duration(milliseconds: 50)));
      // All others should be defaults
      expect(config.probeInterval, equals(const Duration(milliseconds: 3000)));
      expect(config.pingTimeout, equals(const Duration(milliseconds: 2000)));
      expect(
        config.indirectPingTimeout,
        equals(const Duration(milliseconds: 2000)),
      );
      expect(config.suspicionThreshold, equals(5));
    });
  });
}
