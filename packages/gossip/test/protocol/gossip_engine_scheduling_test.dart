import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/protocol/gossip_engine.dart';

void main() {
  group('GossipEngine scheduling', () {
    test('start begins periodic gossip rounds', () {
      final localNode = NodeId('local');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final entryRepo = InMemoryEntryRepository();
      final timer = InMemoryTimePort();
      final bus = InMemoryMessageBus();
      final messagePort = InMemoryMessagePort(localNode, bus);

      final engine = GossipEngine(
        localNode: localNode,
        peerRegistry: peerRegistry,
        entryRepository: entryRepo,
        timePort: timer,
        messagePort: messagePort,
      );

      engine.start();

      // Timer should be scheduled
      expect(engine.isRunning, isTrue);
    });

    test('stop cancels gossip rounds', () {
      final localNode = NodeId('local');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      final entryRepo = InMemoryEntryRepository();
      final timer = InMemoryTimePort();
      final bus = InMemoryMessageBus();
      final messagePort = InMemoryMessagePort(localNode, bus);

      final engine = GossipEngine(
        localNode: localNode,
        peerRegistry: peerRegistry,
        entryRepository: entryRepo,
        timePort: timer,
        messagePort: messagePort,
      );

      engine.start();
      expect(engine.isRunning, isTrue);

      engine.stop();
      expect(engine.isRunning, isFalse);
    });
  });
}
