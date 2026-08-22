import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/application/interfaces/message_dispatcher.dart';
import 'package:gossip_bluey/src/infrastructure/ports/bluey_message_port.dart';

class _FakeService implements MessageDispatcher {
  final List<(NodeId, Uint8List, MessagePriority)> sent = [];
  final StreamController<IncomingMessage> incoming =
      StreamController<IncomingMessage>.broadcast();
  bool closed = false;

  @override
  Future<void> sendGossipMessage(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
    sent.add((destination, bytes, priority));
  }

  @override
  Stream<IncomingMessage> get incomingMessages => incoming.stream;

  @override
  int pendingSendCount(NodeId peer) => 0;

  @override
  int get totalPendingSendCount => 0;

  @override
  Future<void> close() async {
    closed = true;
    await incoming.close();
  }
}

void main() {
  group('BlueyMessagePort', () {
    test('forwards send to the dispatcher', () async {
      final svc = _FakeService();
      final port = BlueyMessagePort(svc);
      final destination = NodeId('11111111-1111-1111-1111-111111111111');
      final bytes = Uint8List.fromList([1, 2, 3]);
      await port.send(destination, bytes, priority: MessagePriority.high);
      expect(svc.sent, hasLength(1));
      expect(svc.sent.first.$1, equals(destination));
      expect(svc.sent.first.$2, equals(bytes));
      expect(svc.sent.first.$3, equals(MessagePriority.high));
    });

    test('exposes incoming messages from the dispatcher', () async {
      final svc = _FakeService();
      final port = BlueyMessagePort(svc);
      final destination = NodeId('11111111-1111-1111-1111-111111111111');
      final received = <IncomingMessage>[];
      final sub = port.incoming.listen(received.add);
      svc.incoming.add(
        IncomingMessage(
          sender: destination,
          bytes: Uint8List.fromList([9]),
          receivedAt: DateTime(2026, 5, 4),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(received, hasLength(1));
      expect(received.first.sender, equals(destination));
    });

    test('close closes the dispatcher', () async {
      final svc = _FakeService();
      final port = BlueyMessagePort(svc);
      await port.close();
      expect(svc.closed, isTrue);
    });
  });
}
