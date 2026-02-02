import 'dart:async';
import 'dart:typed_data';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'message_port.dart';

/// Shared message router for simulating network communication in-process.
///
/// [InMemoryMessageBus] acts as a central message router that delivers
/// messages between [InMemoryMessagePort] instances within the same process.
/// This enables testing multi-node gossip scenarios without requiring actual
/// network communication.
///
/// ## Usage
/// ```dart
/// final bus = InMemoryMessageBus();
/// final port1 = InMemoryMessagePort(NodeId('node1'), bus);
/// final port2 = InMemoryMessagePort(NodeId('node2'), bus);
///
/// // Messages sent via port1 can be received by port2
/// await port1.send(NodeId('node2'), bytes);
/// ```
///
/// The bus maintains a registry of active ports and routes messages to the
/// appropriate recipients based on destination [NodeId].
class InMemoryMessageBus {
  final Map<NodeId, StreamController<IncomingMessage>> _ports = {};

  /// Registers a port for a node to receive messages.
  ///
  /// The controller will receive [IncomingMessage] instances when other
  /// nodes send messages to this node ID.
  void register(NodeId nodeId, StreamController<IncomingMessage> controller) {
    _ports[nodeId] = controller;
  }

  /// Unregisters a port, stopping message delivery to this node.
  void unregister(NodeId nodeId) {
    _ports.remove(nodeId);
  }

  /// Delivers a message from sender to destination.
  ///
  /// If the destination port is not registered or is closed, the message
  /// is silently dropped (simulating network unreachability).
  void deliver(NodeId destination, NodeId sender, Uint8List bytes) {
    final controller = _ports[destination];
    if (controller != null && !controller.isClosed) {
      controller.add(
        IncomingMessage(
          sender: sender,
          bytes: bytes,
          receivedAt: DateTime.now(),
        ),
      );
    }
  }
}

/// In-memory implementation of [MessagePort] for testing.
///
/// Routes messages through a shared [InMemoryMessageBus] within the same
/// process, enabling multi-node testing without real network communication.
///
/// **Use only for testing.**
///
/// Messages sent via one port's [send] method are immediately delivered to
/// the destination port's [incoming] stream if both ports share the same bus.
///
/// This simulates a perfect network (no delays, packet loss, or reordering)
/// unless additional test harness logic is added to the bus.
class InMemoryMessagePort implements MessagePort {
  /// The node ID this port represents.
  final NodeId localNode;

  /// The shared bus for message routing.
  final InMemoryMessageBus bus;

  final StreamController<IncomingMessage> _controller;

  /// Creates a port and registers it with the bus.
  InMemoryMessagePort(this.localNode, this.bus)
    : _controller = StreamController<IncomingMessage>.broadcast() {
    bus.register(localNode, _controller);
  }

  @override
  Future<void> send(NodeId destination, Uint8List bytes) async {
    bus.deliver(destination, localNode, bytes);
  }

  @override
  Stream<IncomingMessage> get incoming => _controller.stream;

  @override
  Future<void> close() async {
    bus.unregister(localNode);
    await _controller.close();
  }

  /// Re-registers this port with the bus after being unregistered.
  ///
  /// Used by test infrastructure to simulate network healing after partition.
  /// Only works if the port hasn't been closed.
  void reregister() {
    if (!_controller.isClosed) {
      bus.register(localNode, _controller);
    }
  }
}
