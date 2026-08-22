import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/interfaces/message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';

void main() {
  final nodeA = NodeId('a');
  final nodeB = NodeId('b');

  late InMemoryMessageBus bus;
  late InMemoryMessagePort portA;
  late InMemoryMessagePort portB;
  late List<IncomingMessage> receivedByA;
  late List<IncomingMessage> receivedByB;

  /// Wires up a fresh bus with two ports and message collectors.
  void setUpBus({BusDeliveryMode? deliveryMode}) {
    bus = deliveryMode == null
        ? InMemoryMessageBus()
        : InMemoryMessageBus(deliveryMode: deliveryMode);
    portA = InMemoryMessagePort(nodeA, bus);
    portB = InMemoryMessagePort(nodeB, bus);
    receivedByA = [];
    receivedByB = [];
    portA.incoming.listen(receivedByA.add);
    portB.incoming.listen(receivedByB.add);
  }

  Uint8List bytes(List<int> data) => Uint8List.fromList(data);

  group('InMemoryMessageBus link blocking', () {
    setUp(setUpBus);

    test('blockLink drops messages in the blocked direction only', () async {
      bus.blockLink(nodeA, nodeB);

      await portA.send(nodeB, bytes([1]));
      await portB.send(nodeA, bytes([2]));
      await pumpEventQueue();

      expect(receivedByB, isEmpty);
      expect(receivedByA, hasLength(1));
      expect(receivedByA.single.bytes, equals(bytes([2])));
    });

    test('unblockLink restores delivery', () async {
      bus.blockLink(nodeA, nodeB);
      await portA.send(nodeB, bytes([1]));
      await pumpEventQueue();
      expect(receivedByB, isEmpty);

      bus.unblockLink(nodeA, nodeB);
      await portA.send(nodeB, bytes([2]));
      await pumpEventQueue();

      expect(receivedByB, hasLength(1));
      expect(receivedByB.single.bytes, equals(bytes([2])));
    });

    test('isLinkBlocked reports per-direction state', () {
      expect(bus.isLinkBlocked(nodeA, nodeB), isFalse);
      bus.blockLink(nodeA, nodeB);
      expect(bus.isLinkBlocked(nodeA, nodeB), isTrue);
      expect(bus.isLinkBlocked(nodeB, nodeA), isFalse);
    });
  });

  group('InMemoryMessageBus targeted drops', () {
    setUp(setUpBus);

    test('dropNextMessages drops exactly N messages then delivers', () async {
      bus.dropNextMessages(nodeA, nodeB, count: 2);

      await portA.send(nodeB, bytes([1]));
      await portA.send(nodeB, bytes([2]));
      await portA.send(nodeB, bytes([3]));
      await pumpEventQueue();

      expect(receivedByB, hasLength(1));
      expect(receivedByB.single.bytes, equals(bytes([3])));
    });

    test('dropNextMessages only affects the given direction', () async {
      bus.dropNextMessages(nodeA, nodeB);

      await portB.send(nodeA, bytes([1]));
      await pumpEventQueue();

      expect(receivedByA, hasLength(1));
    });

    test('dropNextMessages rejects non-positive counts', () {
      expect(
        () => bus.dropNextMessages(nodeA, nodeB, count: 0),
        throwsArgumentError,
      );
    });
  });

  group('InMemoryMessageBus probabilistic drops', () {
    setUp(setUpBus);

    test('drop rate of 1.0 drops everything', () async {
      bus.setDropRate(nodeA, nodeB, 1.0, random: Random(1));

      for (var i = 0; i < 10; i++) {
        await portA.send(nodeB, bytes([i]));
      }
      await pumpEventQueue();

      expect(receivedByB, isEmpty);
    });

    test('drop rate of 0.0 delivers everything', () async {
      bus.setDropRate(nodeA, nodeB, 0.0, random: Random(1));

      for (var i = 0; i < 10; i++) {
        await portA.send(nodeB, bytes([i]));
      }
      await pumpEventQueue();

      expect(receivedByB, hasLength(10));
    });

    test('same seed produces the same drop pattern', () async {
      Future<List<int>> deliveredWithSeed(int seed) async {
        setUpBus();
        bus.setDropRate(nodeA, nodeB, 0.5, random: Random(seed));
        for (var i = 0; i < 30; i++) {
          await portA.send(nodeB, bytes([i]));
        }
        await pumpEventQueue();
        return receivedByB.map((m) => m.bytes[0]).toList();
      }

      final first = await deliveredWithSeed(7);
      final second = await deliveredWithSeed(7);

      expect(first, equals(second));
      expect(first, isNotEmpty);
      expect(first.length, lessThan(30));
    });

    test('clearDropRate stops probabilistic drops', () async {
      bus.setDropRate(nodeA, nodeB, 1.0, random: Random(1));
      bus.clearDropRate(nodeA, nodeB);

      await portA.send(nodeB, bytes([1]));
      await pumpEventQueue();

      expect(receivedByB, hasLength(1));
    });

    test('setDropRate rejects rates outside [0, 1]', () {
      expect(
        () => bus.setDropRate(nodeA, nodeB, 1.5, random: Random(1)),
        throwsArgumentError,
      );
      expect(
        () => bus.setDropRate(nodeA, nodeB, -0.1, random: Random(1)),
        throwsArgumentError,
      );
    });
  });

  group('InMemoryMessageBus duplication', () {
    setUp(setUpBus);

    test('duplicateNextMessages delivers the next message twice', () async {
      bus.duplicateNextMessages(nodeA, nodeB);

      await portA.send(nodeB, bytes([1]));
      await portA.send(nodeB, bytes([2]));
      await pumpEventQueue();

      expect(receivedByB.map((m) => m.bytes[0]).toList(), equals([1, 1, 2]));
    });

    test('duplicate rate of 1.0 duplicates every message', () async {
      bus.setDuplicateRate(nodeA, nodeB, 1.0, random: Random(1));

      await portA.send(nodeB, bytes([1]));
      await portA.send(nodeB, bytes([2]));
      await pumpEventQueue();

      expect(receivedByB.map((m) => m.bytes[0]).toList(), equals([1, 1, 2, 2]));
    });

    test('same seed produces the same duplication pattern', () async {
      Future<List<int>> deliveredWithSeed(int seed) async {
        setUpBus();
        bus.setDuplicateRate(nodeA, nodeB, 0.5, random: Random(seed));
        for (var i = 0; i < 30; i++) {
          await portA.send(nodeB, bytes([i]));
        }
        await pumpEventQueue();
        return receivedByB.map((m) => m.bytes[0]).toList();
      }

      final first = await deliveredWithSeed(11);
      final second = await deliveredWithSeed(11);

      expect(first, equals(second));
      expect(first.length, greaterThan(30));
    });

    test('clearDuplicateRate stops duplication', () async {
      bus.setDuplicateRate(nodeA, nodeB, 1.0, random: Random(1));
      bus.clearDuplicateRate(nodeA, nodeB);

      await portA.send(nodeB, bytes([1]));
      await pumpEventQueue();

      expect(receivedByB, hasLength(1));
    });
  });

  group('InMemoryMessageBus corruption', () {
    setUp(setUpBus);

    Uint8List zeroOut(Uint8List input) =>
        Uint8List.fromList(List.filled(input.length, 0));

    test('corruptNextMessages transforms only the next N messages', () async {
      bus.corruptNextMessages(nodeA, nodeB, zeroOut);

      await portA.send(nodeB, bytes([1, 2]));
      await portA.send(nodeB, bytes([3, 4]));
      await pumpEventQueue();

      expect(receivedByB[0].bytes, equals(bytes([0, 0])));
      expect(receivedByB[1].bytes, equals(bytes([3, 4])));
    });

    test('setLinkCorruption transforms all messages until cleared', () async {
      bus.setLinkCorruption(nodeA, nodeB, zeroOut);

      await portA.send(nodeB, bytes([1]));
      await portA.send(nodeB, bytes([2]));
      await pumpEventQueue();

      expect(receivedByB[0].bytes, equals(bytes([0])));
      expect(receivedByB[1].bytes, equals(bytes([0])));

      bus.clearLinkCorruption(nodeA, nodeB);
      await portA.send(nodeB, bytes([3]));
      await pumpEventQueue();

      expect(receivedByB[2].bytes, equals(bytes([3])));
    });

    test('corruption applies to the given direction only', () async {
      bus.setLinkCorruption(nodeA, nodeB, zeroOut);

      await portB.send(nodeA, bytes([5]));
      await pumpEventQueue();

      expect(receivedByA.single.bytes, equals(bytes([5])));
    });
  });

  group('InMemoryMessageBus held (in-flight) messages', () {
    setUp(setUpBus);

    test('holdLink queues messages instead of delivering', () async {
      bus.holdLink(nodeA, nodeB);

      await portA.send(nodeB, bytes([1]));
      await portA.send(nodeB, bytes([2]));
      await pumpEventQueue();

      expect(receivedByB, isEmpty);
      expect(bus.heldMessageCount(nodeA, nodeB), equals(2));
    });

    test('flushHeldMessages delivers held messages in order '
        'but keeps holding new sends', () async {
      bus.holdLink(nodeA, nodeB);
      await portA.send(nodeB, bytes([1]));
      await portA.send(nodeB, bytes([2]));

      bus.flushHeldMessages(from: nodeA, to: nodeB);
      await pumpEventQueue();

      expect(receivedByB.map((m) => m.bytes[0]).toList(), equals([1, 2]));
      expect(bus.heldMessageCount(nodeA, nodeB), equals(0));

      await portA.send(nodeB, bytes([3]));
      await pumpEventQueue();
      expect(receivedByB, hasLength(2));
      expect(bus.heldMessageCount(nodeA, nodeB), equals(1));
    });

    test('flushHeldMessages with no arguments flushes all links', () async {
      bus.holdLink(nodeA, nodeB);
      bus.holdLink(nodeB, nodeA);
      await portA.send(nodeB, bytes([1]));
      await portB.send(nodeA, bytes([2]));

      bus.flushHeldMessages();
      await pumpEventQueue();

      expect(receivedByB, hasLength(1));
      expect(receivedByA, hasLength(1));
    });

    test('releaseLink flushes held messages and stops holding', () async {
      bus.holdLink(nodeA, nodeB);
      await portA.send(nodeB, bytes([1]));

      bus.releaseLink(nodeA, nodeB);
      await pumpEventQueue();

      expect(receivedByB, hasLength(1));

      await portA.send(nodeB, bytes([2]));
      await pumpEventQueue();
      expect(receivedByB, hasLength(2));
    });

    test('held messages to an unregistered destination are dropped '
        'on flush (network unreachability)', () async {
      bus.holdLink(nodeA, nodeB);
      await portA.send(nodeB, bytes([1]));

      bus.unregister(nodeB);
      bus.flushHeldMessages(from: nodeA, to: nodeB);
      await pumpEventQueue();

      expect(receivedByB, isEmpty);
      expect(bus.heldMessageCount(nodeA, nodeB), equals(0));
    });

    test('duplicated messages are held as two copies', () async {
      bus.holdLink(nodeA, nodeB);
      bus.duplicateNextMessages(nodeA, nodeB);

      await portA.send(nodeB, bytes([1]));

      expect(bus.heldMessageCount(nodeA, nodeB), equals(2));
    });

    test('totalHeldMessagesFrom sums held messages across links', () async {
      final nodeC = NodeId('c');
      InMemoryMessagePort(nodeC, bus);

      bus.holdLink(nodeA, nodeB);
      bus.holdLink(nodeA, nodeC);
      await portA.send(nodeB, bytes([1]));
      await portA.send(nodeC, bytes([2]));
      await portA.send(nodeC, bytes([3]));

      expect(bus.totalHeldMessagesFrom(nodeA), equals(3));
    });
  });

  group('InMemoryMessagePort emergent backpressure', () {
    setUp(setUpBus);

    test('pendingSendCount reflects held messages on the link', () async {
      bus.holdLink(nodeA, nodeB);

      expect(portA.pendingSendCount(nodeB), equals(0));

      await portA.send(nodeB, bytes([1]));
      await portA.send(nodeB, bytes([2]));

      expect(portA.pendingSendCount(nodeB), equals(2));

      bus.releaseLink(nodeA, nodeB);
      await pumpEventQueue();

      expect(portA.pendingSendCount(nodeB), equals(0));
    });

    test('simulated pending counts still work and combine with held '
        'messages', () async {
      bus.holdLink(nodeA, nodeB);
      await portA.send(nodeB, bytes([1]));

      portA.setSimulatedPendingCount(5);
      expect(portA.pendingSendCount(nodeB), equals(6));

      portA.setSimulatedPendingCountForPeer(nodeB, 10);
      expect(portA.pendingSendCount(nodeB), equals(11));

      portA.clearSimulatedPendingCounts();
      expect(portA.pendingSendCount(nodeB), equals(1));
    });

    test('totalPendingSendCount includes held messages', () async {
      bus.holdLink(nodeA, nodeB);
      await portA.send(nodeB, bytes([1]));
      await portA.send(nodeB, bytes([2]));

      expect(portA.totalPendingSendCount, equals(2));

      portA.setSimulatedPendingCount(3);
      expect(portA.totalPendingSendCount, equals(5));
    });
  });

  group('InMemoryMessageBus delivery modes', () {
    test('asynchronous mode (default) never delivers synchronously', () async {
      setUpBus();

      unawaited(portA.send(nodeB, bytes([1])));
      expect(receivedByB, isEmpty);

      await pumpEventQueue();
      expect(receivedByB, hasLength(1));
    });

    test('asynchronous mode preserves send order', () async {
      setUpBus();

      for (var i = 0; i < 5; i++) {
        unawaited(portA.send(nodeB, bytes([i])));
      }
      await pumpEventQueue();

      expect(
        receivedByB.map((m) => m.bytes[0]).toList(),
        equals([0, 1, 2, 3, 4]),
      );
    });

    test('synchronous mode still delivers', () async {
      setUpBus(deliveryMode: BusDeliveryMode.synchronous);

      await portA.send(nodeB, bytes([1]));
      await pumpEventQueue();

      expect(receivedByB, hasLength(1));
    });
  });

  group('InMemoryMessageBus condition cleanup', () {
    setUp(setUpBus);

    test('clearLinkConditions resets a single link and flushes held '
        'messages', () async {
      bus.blockLink(nodeA, nodeB);
      bus.clearLinkConditions(nodeA, nodeB);

      await portA.send(nodeB, bytes([1]));
      await pumpEventQueue();
      expect(receivedByB, hasLength(1));

      bus.holdLink(nodeA, nodeB);
      await portA.send(nodeB, bytes([2]));
      bus.clearLinkConditions(nodeA, nodeB);
      await pumpEventQueue();
      expect(receivedByB, hasLength(2));
    });

    test('clearAllLinkConditions resets every link', () async {
      bus.blockLink(nodeA, nodeB);
      bus.blockLink(nodeB, nodeA);
      bus.clearAllLinkConditions();

      await portA.send(nodeB, bytes([1]));
      await portB.send(nodeA, bytes([2]));
      await pumpEventQueue();

      expect(receivedByB, hasLength(1));
      expect(receivedByA, hasLength(1));
    });
  });
}
