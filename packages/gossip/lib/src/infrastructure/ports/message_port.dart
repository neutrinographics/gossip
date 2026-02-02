import 'dart:typed_data';
import 'package:gossip/src/domain/value_objects/node_id.dart';

/// A message received from a peer.
///
/// Contains the raw bytes along with metadata about when and from whom
/// the message was received.
class IncomingMessage {
  /// The node that sent this message.
  final NodeId sender;

  /// The raw message bytes (to be decoded by ProtocolCodec).
  final Uint8List bytes;

  /// When this message was received (local wall-clock time).
  final DateTime receivedAt;

  IncomingMessage({
    required this.sender,
    required this.bytes,
    required this.receivedAt,
  });
}

/// Port abstraction for network communication between peers.
///
/// [MessagePort] decouples the gossip library from specific transport
/// mechanisms, enabling support for:
/// - **Bluetooth**: Android Nearby Connections, CoreBluetooth
/// - **TCP/UDP**: Direct socket connections
/// - **WebRTC**: Browser-to-browser communication
/// - **Custom transports**: Any peer-to-peer communication channel
///
/// Applications provide a concrete implementation matching their chosen
/// transport layer.
///
/// ## Implementation Example
///
/// ```dart
/// class BluetoothMessagePort implements MessagePort {
///   final _controller = StreamController<IncomingMessage>.broadcast();
///   final BluetoothAdapter _adapter;
///
///   BluetoothMessagePort(this._adapter) {
///     _adapter.onReceive.listen((data) {
///       _controller.add(IncomingMessage(
///         sender: NodeId(data.deviceId),
///         bytes: data.bytes,
///         receivedAt: DateTime.now(),
///       ));
///     });
///   }
///
///   @override
///   Future<void> send(NodeId destination, Uint8List bytes) async {
///     await _adapter.sendToDevice(destination.value, bytes);
///   }
///
///   @override
///   Stream<IncomingMessage> get incoming => _controller.stream;
///
///   @override
///   Future<void> close() async {
///     await _controller.close();
///     await _adapter.disconnect();
///   }
/// }
/// ```
///
/// ## Contract
///
/// - **Best-effort delivery**: The library handles message loss via retransmission
/// - **Non-blocking send**: `send()` should return quickly (queue if needed)
/// - **No exceptions on failure**: Network errors should be logged, not thrown
/// - **Message size**: Support at least 32KB payloads (Android Nearby limit)
///
/// ## Testing
/// Use [InMemoryMessagePort] with [InMemoryMessageBus] to test multi-node
/// scenarios without real network communication.
///
/// ## Threading
/// The port may deliver messages on any thread/isolate. Implementations
/// should ensure thread safety if accessed from multiple contexts.
///
/// See also:
/// - [InMemoryMessagePort] for the reference implementation
/// - ADR-006 for the design rationale
abstract class MessagePort {
  /// Sends bytes to a destination peer.
  ///
  /// The implementation should:
  /// - Deliver bytes best-effort (no guaranteed delivery)
  /// - Not block the caller (async delivery)
  /// - Handle unreachable destinations gracefully (no exceptions)
  Future<void> send(NodeId destination, Uint8List bytes);

  /// Stream of messages received from peers.
  ///
  /// The library listens to this stream to handle incoming protocol messages.
  /// Messages arrive in the order received by the transport layer.
  Stream<IncomingMessage> get incoming;

  /// Closes the port and releases resources.
  ///
  /// After closing, no more messages can be sent or received.
  Future<void> close();
}
