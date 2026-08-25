import 'package:gossip/src/coordinator/coordinator_config.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:test/test.dart';

import '../support/coordinator_builder.dart';

/// Verifies that the four timing knobs on [CoordinatorConfig]
/// (`gossipInterval`, `probeInterval`, `pingTimeout`,
/// `adaptiveTimingEnabled`) are plumbed through `Coordinator.create`
/// into the `GossipEngine` and `FailureDetector` constructors.
///
/// Assertions rely on `Coordinator.getAdaptiveTimingStatus()` which
/// exposes the effective intervals computed by each component.
void main() {
  group('Coordinator timing passthrough', () {
    test(
      'static gossipInterval from CoordinatorConfig reaches GossipEngine',
      () async {
        final coord = await createTestCoordinator(
          bus: InMemoryMessageBus(),
          timePort: InMemoryTimePort(),
          config: const CoordinatorConfig(
            gossipInterval: Duration(milliseconds: 250),
          ),
        );

        final status = coord.getAdaptiveTimingStatus();
        expect(status, isNotNull);
        expect(
          status!.effectiveGossipInterval,
          equals(const Duration(milliseconds: 250)),
        );
      },
    );

    test(
      'static probeInterval from CoordinatorConfig reaches FailureDetector',
      () async {
        final coord = await createTestCoordinator(
          bus: InMemoryMessageBus(),
          timePort: InMemoryTimePort(),
          config: const CoordinatorConfig(
            probeInterval: Duration(milliseconds: 750),
          ),
        );

        final status = coord.getAdaptiveTimingStatus();
        expect(status, isNotNull);
        expect(
          status!.effectiveProbeInterval,
          equals(const Duration(milliseconds: 750)),
        );
      },
    );

    test(
      'static pingTimeout from CoordinatorConfig reaches FailureDetector',
      () async {
        final coord = await createTestCoordinator(
          bus: InMemoryMessageBus(),
          timePort: InMemoryTimePort(),
          config: const CoordinatorConfig(pingTimeout: Duration(seconds: 2)),
        );

        final status = coord.getAdaptiveTimingStatus();
        expect(status, isNotNull);
        expect(
          status!.effectivePingTimeout,
          equals(const Duration(seconds: 2)),
        );
      },
    );

    test('null defaults preserve adaptive behavior', () async {
      final coord = await createTestCoordinator(
        bus: InMemoryMessageBus(),
        timePort: InMemoryTimePort(),
      );

      final status = coord.getAdaptiveTimingStatus();
      expect(status, isNotNull);
      // With no peers and no RTT samples, the gossip engine falls back
      // to its 1000ms conservative default — distinct from any explicit
      // value the static-passthrough tests use.
      expect(
        status!.effectiveGossipInterval,
        equals(const Duration(milliseconds: 1000)),
      );
    });

    test('adaptiveTimingEnabled: false propagates to GossipEngine', () async {
      // When adaptive timing is disabled and no static gossipInterval is
      // provided, GossipEngine falls back to its 500ms internal default.
      // This is distinct from both the adaptive fallback (1000ms) and
      // the explicit value used by the static-passthrough test (250ms).
      final coord = await createTestCoordinator(
        bus: InMemoryMessageBus(),
        timePort: InMemoryTimePort(),
        config: const CoordinatorConfig(adaptiveTimingEnabled: false),
      );

      final status = coord.getAdaptiveTimingStatus();
      expect(status, isNotNull);
      expect(
        status!.effectiveGossipInterval,
        equals(const Duration(milliseconds: 500)),
      );
    });
  });
}
