import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../application/interfaces/message_dispatcher.dart';

/// Implements gossip's MessagePort by delegating to a MessageDispatcher.
///
/// This adapter decouples the gossip protocol from the connection service,
/// allowing both to be tested independently while maintaining the messaging
/// contract required by the Coordinator.
class BlueyMessagePort implements MessagePort {
  final MessageDispatcher _dispatcher;

  BlueyMessagePort(this._dispatcher);

  @override
  Future<void> send(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) {
    return _dispatcher.sendGossipMessage(
      destination,
      bytes,
      priority: priority,
    );
  }

  @override
  Stream<IncomingMessage> get incoming => _dispatcher.incomingMessages;

  @override
  int pendingSendCount(NodeId peer) => _dispatcher.pendingSendCount(peer);

  @override
  int get totalPendingSendCount => _dispatcher.totalPendingSendCount;

  @override
  Future<void> close() => _dispatcher.close();
}
