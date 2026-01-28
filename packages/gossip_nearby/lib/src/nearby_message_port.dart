import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import 'nearby_connection_manager.dart';

/// MessagePort implementation backed by Nearby Connections.
///
/// This class bridges the gossip library's [MessagePort] interface with
/// [NearbyConnectionManager], translating between gossip's NodeId-based
/// addressing and Nearby's endpoint-based communication.
class NearbyMessagePort implements MessagePort {
  final NearbyConnectionManager _connectionManager;
  final StreamController<IncomingMessage> _incoming =
      StreamController<IncomingMessage>.broadcast();
  StreamSubscription<(NodeId, Uint8List)>? _subscription;

  NearbyMessagePort(this._connectionManager) {
    _subscription = _connectionManager.incomingPayloads.listen(_onPayload);
  }

  void _onPayload((NodeId, Uint8List) payload) {
    final (sender, bytes) = payload;
    _incoming.add(
      IncomingMessage(sender: sender, bytes: bytes, receivedAt: DateTime.now()),
    );
  }

  @override
  Future<void> send(NodeId destination, Uint8List bytes) async {
    // Best-effort delivery - don't throw on failure
    await _connectionManager.sendTo(destination, bytes);
  }

  @override
  Stream<IncomingMessage> get incoming => _incoming.stream;

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    await _incoming.close();
  }
}
