import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_chat/application/services/gossip_config_service.dart';

void main() {
  group('GossipConfigService', () {
    test('defaults: both intervals null (adaptive)', () {
      final s = GossipConfigService();
      expect(s.gossipInterval, isNull);
      expect(s.probeInterval, isNull);
    });

    test('setGossipInterval updates and notifies', () {
      final s = GossipConfigService();
      var notified = 0;
      s.addListener(() => notified++);
      s.setGossipInterval(const Duration(milliseconds: 250));
      expect(s.gossipInterval, const Duration(milliseconds: 250));
      expect(notified, 1);
    });

    test('setGossipInterval(same value) does not notify', () {
      final s = GossipConfigService();
      s.setGossipInterval(const Duration(milliseconds: 250));
      var notified = 0;
      s.addListener(() => notified++);
      s.setGossipInterval(const Duration(milliseconds: 250));
      expect(notified, 0);
    });

    test('setProbeInterval updates and notifies', () {
      final s = GossipConfigService();
      var notified = 0;
      s.addListener(() => notified++);
      s.setProbeInterval(const Duration(milliseconds: 800));
      expect(s.probeInterval, const Duration(milliseconds: 800));
      expect(notified, 1);
    });

    test('reset to null (adaptive) is reflected', () {
      final s = GossipConfigService();
      s.setGossipInterval(const Duration(milliseconds: 250));
      s.setGossipInterval(null);
      expect(s.gossipInterval, isNull);
    });

    test('buildCoordinatorConfig with default state', () {
      final s = GossipConfigService();
      final cfg = s.buildCoordinatorConfig();
      expect(cfg.gossipInterval, isNull);
      expect(cfg.probeInterval, isNull);
      expect(cfg.adaptiveTimingEnabled, isTrue); // CoordinatorConfig default
    });

    test('buildCoordinatorConfig with explicit values', () {
      final s = GossipConfigService();
      s.setGossipInterval(const Duration(milliseconds: 250));
      s.setProbeInterval(const Duration(milliseconds: 750));
      final cfg = s.buildCoordinatorConfig();
      expect(cfg.gossipInterval, const Duration(milliseconds: 250));
      expect(cfg.probeInterval, const Duration(milliseconds: 750));
    });
  });
}
