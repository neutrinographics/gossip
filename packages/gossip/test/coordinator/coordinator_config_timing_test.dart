import 'package:gossip/src/coordinator/coordinator_config.dart';
import 'package:test/test.dart';

void main() {
  group('CoordinatorConfig timing knobs', () {
    test('defaults are all null (= adaptive)', () {
      const cfg = CoordinatorConfig();
      expect(cfg.gossipInterval, isNull);
      expect(cfg.probeInterval, isNull);
      expect(cfg.pingTimeout, isNull);
      expect(cfg.adaptiveTimingEnabled, isTrue);
    });

    test('explicit values are preserved', () {
      const cfg = CoordinatorConfig(
        gossipInterval: Duration(milliseconds: 250),
        probeInterval: Duration(milliseconds: 750),
        pingTimeout: Duration(seconds: 2),
        adaptiveTimingEnabled: false,
      );
      expect(cfg.gossipInterval, const Duration(milliseconds: 250));
      expect(cfg.probeInterval, const Duration(milliseconds: 750));
      expect(cfg.pingTimeout, const Duration(seconds: 2));
      expect(cfg.adaptiveTimingEnabled, isFalse);
    });

    test('CoordinatorConfig.defaults still has null timing fields', () {
      expect(CoordinatorConfig.defaults.gossipInterval, isNull);
      expect(CoordinatorConfig.defaults.probeInterval, isNull);
      expect(CoordinatorConfig.defaults.pingTimeout, isNull);
      expect(CoordinatorConfig.defaults.adaptiveTimingEnabled, isTrue);
    });
  });
}
