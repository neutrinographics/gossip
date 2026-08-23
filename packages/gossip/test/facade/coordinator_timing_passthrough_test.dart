import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/facade/coordinator.dart';
import 'package:gossip/src/facade/coordinator_config.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/membership/infrastructure/in_memory_peer_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:test/test.dart';

/// Verifies that the four timing knobs on [CoordinatorConfig]
/// (`gossipInterval`, `probeInterval`, `pingTimeout`,
/// `adaptiveTimingEnabled`) are plumbed through `Coordinator.create`
/// into the `GossipEngine` and `FailureDetector` constructors.
///
/// Assertions rely on `Coordinator.getAdaptiveTimingStatus()` which
/// exposes the effective intervals computed by each component.
void main() {
  group('Coordinator timing passthrough', () {
    late NodeId localNode;

    setUp(() {
      localNode = NodeId('local');
    });

    test(
      'static gossipInterval from CoordinatorConfig reaches GossipEngine',
      () async {
        final coord = await _createCoordinator(
          localNode: localNode,
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

        await coord.dispose();
      },
    );

    test(
      'static probeInterval from CoordinatorConfig reaches FailureDetector',
      () async {
        final coord = await _createCoordinator(
          localNode: localNode,
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

        await coord.dispose();
      },
    );

    test(
      'static pingTimeout from CoordinatorConfig reaches FailureDetector',
      () async {
        final coord = await _createCoordinator(
          localNode: localNode,
          config: const CoordinatorConfig(
            pingTimeout: Duration(seconds: 2),
          ),
        );

        final status = coord.getAdaptiveTimingStatus();
        expect(status, isNotNull);
        expect(
          status!.effectivePingTimeout,
          equals(const Duration(seconds: 2)),
        );

        await coord.dispose();
      },
    );

    test('null defaults preserve adaptive behavior', () async {
      final coord = await _createCoordinator(localNode: localNode);

      final status = coord.getAdaptiveTimingStatus();
      expect(status, isNotNull);
      // With no peers and no RTT samples, the gossip engine falls back
      // to its 1000ms conservative default — distinct from any explicit
      // value the static-passthrough tests use.
      expect(
        status!.effectiveGossipInterval,
        equals(const Duration(milliseconds: 1000)),
      );

      await coord.dispose();
    });

    test(
      'adaptiveTimingEnabled: false propagates to GossipEngine',
      () async {
        // When adaptive timing is disabled and no static gossipInterval is
        // provided, GossipEngine falls back to its 500ms internal default.
        // This is distinct from both the adaptive fallback (1000ms) and
        // the explicit value used by the static-passthrough test (250ms).
        final coord = await _createCoordinator(
          localNode: localNode,
          config: const CoordinatorConfig(adaptiveTimingEnabled: false),
        );

        final status = coord.getAdaptiveTimingStatus();
        expect(status, isNotNull);
        expect(
          status!.effectiveGossipInterval,
          equals(const Duration(milliseconds: 500)),
        );

        await coord.dispose();
      },
    );
  });
}

Future<Coordinator> _createCoordinator({
  required NodeId localNode,
  CoordinatorConfig? config,
}) async {
  final bus = InMemoryMessageBus();
  return Coordinator.create(
    localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
    channelRepository: InMemoryChannelRepository(),
    peerRepository: InMemoryPeerRepository(),
    entryRepository: InMemoryEntryRepository(),
    messagePort: InMemoryMessagePort(localNode, bus),
    timerPort: InMemoryTimePort(),
    config: config,
  );
}
