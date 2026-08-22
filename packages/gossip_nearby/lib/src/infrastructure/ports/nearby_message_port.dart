import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../application/interfaces/message_dispatcher.dart';

/// Implements gossip's [MessagePort] interface using a [MessageDispatcher].
///
/// This adapter bridges the gossip library's messaging abstraction with
/// the Nearby Connections transport layer, depending only on the
/// application-owned dispatcher seam (ARCH3-4) rather than the concrete
/// `ConnectionService`.
class NearbyMessagePort implements MessagePort {
  final MessageDispatcher _dispatcher;
  bool _closed = false;

  final StreamController<IncomingMessage> _incomingController =
      StreamController<IncomingMessage>.broadcast();
  late final StreamSubscription<IncomingMessage> _incomingSubscription;

  NearbyMessagePort(this._dispatcher) {
    _incomingSubscription = _dispatcher.incomingMessages.listen(
      _incomingController.add,
    );
  }

  @override
  Future<void> send(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
    if (_closed) return;
    await _dispatcher.sendGossipMessage(destination, bytes, priority: priority);
  }

  @override
  Stream<IncomingMessage> get incoming => _incomingController.stream;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incomingSubscription.cancel();
    await _incomingController.close();
  }

  @override
  int pendingSendCount(NodeId peer) => _dispatcher.pendingSendCount(peer);

  @override
  int get totalPendingSendCount => _dispatcher.totalPendingSendCount;
}
