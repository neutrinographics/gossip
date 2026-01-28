import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../application/services/connection_service.dart';

/// Implements gossip's [MessagePort] interface using [ConnectionService].
///
/// This adapter bridges the gossip library's messaging abstraction with
/// the Nearby Connections transport layer.
class NearbyMessagePort implements MessagePort {
  final ConnectionService _connectionService;
  final _incomingController = StreamController<IncomingMessage>.broadcast();
  bool _closed = false;

  NearbyMessagePort(this._connectionService) {
    _connectionService.onGossipMessage = _onGossipMessage;
  }

  void _onGossipMessage(NodeId sender, Uint8List bytes) {
    if (_closed) return;

    _incomingController.add(
      IncomingMessage(sender: sender, bytes: bytes, receivedAt: DateTime.now()),
    );
  }

  @override
  Future<void> send(NodeId destination, Uint8List bytes) async {
    if (_closed) return;
    await _connectionService.sendGossipMessage(destination, bytes);
  }

  @override
  Stream<IncomingMessage> get incoming => _incomingController.stream;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _connectionService.onGossipMessage = null;
    await _incomingController.close();
  }
}
