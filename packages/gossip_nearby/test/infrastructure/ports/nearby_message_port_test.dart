import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/src/application/interfaces/message_dispatcher.dart';
import 'package:gossip_nearby/src/infrastructure/ports/nearby_message_port.dart';

class _FakeDispatcher implements MessageDispatcher {
  final sent = <(NodeId, Uint8List)>[];
  final _incoming = StreamController<IncomingMessage>.broadcast();

  @override
  Future<void> sendGossipMessage(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
    sent.add((destination, bytes));
  }

  @override
  Stream<IncomingMessage> get incomingMessages => _incoming.stream;

  @override
  int pendingSendCount(NodeId peer) => 0;

  @override
  int get totalPendingSendCount => 0;

  void emit(IncomingMessage m) => _incoming.add(m);
}

void main() {
  final peer = NodeId('22222222-2222-2222-2222-222222222222');

  test('port sends through the dispatcher interface', () async {
    final dispatcher = _FakeDispatcher();
    final port = NearbyMessagePort(dispatcher);
    await port.send(peer, Uint8List.fromList([1, 2, 3]));
    expect(dispatcher.sent.single.$1, peer);
  });

  test('port forwards the dispatcher incoming stream', () async {
    final dispatcher = _FakeDispatcher();
    final port = NearbyMessagePort(dispatcher);
    final received = <IncomingMessage>[];
    final sub = port.incoming.listen(received.add);

    dispatcher.emit(
      IncomingMessage(
        sender: peer,
        bytes: Uint8List.fromList([7]),
        receivedAt: DateTime.now(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(received.single.sender, peer);
    await sub.cancel();
  });

  test('close can be called multiple times without error', () async {
    final dispatcher = _FakeDispatcher();
    final port = NearbyMessagePort(dispatcher);
    await port.close();
    await port.close();
    // No exception = pass
  });

  test('a closed port delivers nothing', () async {
    final dispatcher = _FakeDispatcher();
    final port = NearbyMessagePort(dispatcher);
    final received = <IncomingMessage>[];
    final sub = port.incoming.listen(received.add);

    await port.close();

    dispatcher.emit(
      IncomingMessage(
        sender: peer,
        bytes: Uint8List.fromList([7]),
        receivedAt: DateTime.now(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(received, isEmpty);
    await sub.cancel();
  });
}
