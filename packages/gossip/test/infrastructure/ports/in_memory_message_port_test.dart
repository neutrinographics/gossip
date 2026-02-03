import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/infrastructure/ports/message_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';

void main() {
  group('InMemoryMessagePort', () {
    test('can send message to destination', () async {
      final bus = InMemoryMessageBus();
      final node1 = NodeId('node1');
      final node2 = NodeId('node2');

      final port1 = InMemoryMessagePort(node1, bus);
      final port2 = InMemoryMessagePort(node2, bus);

      // Listen for incoming message
      final messageFuture = port2.incoming.first;

      final bytes = Uint8List.fromList([1, 2, 3]);
      await port1.send(node2, bytes);

      // Message should be delivered
      final message = await messageFuture;
      expect(message.sender, equals(node1));
      expect(message.bytes, equals(bytes));
    });

    test('messages to unknown destinations are dropped', () async {
      final bus = InMemoryMessageBus();
      final node1 = NodeId('node1');
      final unknownNode = NodeId('unknown');

      final port1 = InMemoryMessagePort(node1, bus);

      final bytes = Uint8List.fromList([1, 2, 3]);
      // Should not throw, just silently drop
      await port1.send(unknownNode, bytes);

      // Test completes without error
      expect(true, isTrue);
    });

    test('can handle multiple nodes', () async {
      final bus = InMemoryMessageBus();
      final node1 = NodeId('node1');
      final node2 = NodeId('node2');
      final node3 = NodeId('node3');

      final port1 = InMemoryMessagePort(node1, bus);
      final port2 = InMemoryMessagePort(node2, bus);
      final port3 = InMemoryMessagePort(node3, bus);

      // node1 -> node2
      final message2Future = port2.incoming.first;
      await port1.send(node2, Uint8List.fromList([1]));
      final message2 = await message2Future;
      expect(message2.sender, equals(node1));

      // node2 -> node3
      final message3Future = port3.incoming.first;
      await port2.send(node3, Uint8List.fromList([2]));
      final message3 = await message3Future;
      expect(message3.sender, equals(node2));
    });

    test('accepts priority parameter for send', () async {
      final bus = InMemoryMessageBus();
      final node1 = NodeId('node1');
      final node2 = NodeId('node2');

      final port1 = InMemoryMessagePort(node1, bus);
      final port2 = InMemoryMessagePort(node2, bus);

      // Listen for incoming messages
      final messages = <IncomingMessage>[];
      port2.incoming.listen(messages.add);

      // Send with high priority
      final highPriorityBytes = Uint8List.fromList([1, 2, 3]);
      await port1.send(
        node2,
        highPriorityBytes,
        priority: MessagePriority.high,
      );

      // Send with normal priority (default)
      final normalPriorityBytes = Uint8List.fromList([4, 5, 6]);
      await port1.send(node2, normalPriorityBytes);

      // Both messages should be delivered (in-memory doesn't queue by priority)
      await Future.delayed(Duration(milliseconds: 10));
      expect(messages, hasLength(2));
      expect(messages[0].bytes, equals(highPriorityBytes));
      expect(messages[1].bytes, equals(normalPriorityBytes));
    });
  });
}
