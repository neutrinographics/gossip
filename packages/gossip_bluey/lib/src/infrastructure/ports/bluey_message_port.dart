import 'dart:typed_data';

import 'package:gossip/gossip.dart';

/// Minimal interface that BlueyMessagePort needs from the connection service.
/// Lets the message port and connection service be tested independently.
abstract interface class MessageDispatcher {
  /// Sends a gossip message to a destination peer.
  Future<void> sendGossipMessage(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  });

  /// Stream of incoming messages from peers.
  Stream<IncomingMessage> get incomingMessages;

  /// Returns the number of messages waiting to be sent to a specific peer.
  int pendingSendCount(NodeId peer);

  /// Returns the total number of messages waiting to be sent across all peers.
  int get totalPendingSendCount;

  /// Closes the dispatcher and releases resources.
  Future<void> close();
}

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
