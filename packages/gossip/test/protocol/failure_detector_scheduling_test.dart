import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/protocol/failure_detector.dart';

void main() {
  group('FailureDetector scheduling', () {
    test('start begins periodic probes', () {
      final localNode = NodeId('local');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final timer = InMemoryTimePort();
      final bus = InMemoryMessageBus();
      final messagePort = InMemoryMessagePort(localNode, bus);

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timer,
        messagePort: messagePort,
      );

      detector.start();

      // Timer should be scheduled
      expect(detector.isRunning, isTrue);
    });

    test('stop cancels probes', () {
      final localNode = NodeId('local');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final timer = InMemoryTimePort();
      final bus = InMemoryMessageBus();
      final messagePort = InMemoryMessagePort(localNode, bus);

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timer,
        messagePort: messagePort,
      );

      detector.start();
      expect(detector.isRunning, isTrue);

      detector.stop();
      expect(detector.isRunning, isFalse);
    });
  });
}
