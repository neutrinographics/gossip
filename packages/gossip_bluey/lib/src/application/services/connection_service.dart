import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../domain/aggregates/connection_registry.dart';
import '../../domain/entities/connection_handle.dart';
import '../../domain/errors/connection_error.dart';
import '../../domain/events/connection_event.dart';
import '../../domain/interfaces/bluey_port.dart';
import '../../domain/value_objects/service_uuid.dart';
import '../../infrastructure/codec/frame_codec.dart';
import '../../infrastructure/ports/bluey_message_port.dart';
import '../observability/bluey_metrics.dart';

/// Trivial clock seam for tests.
class Clock {
  const Clock();
  DateTime now() => DateTime.now();
}

class ConnectionService implements MessageDispatcher {
  ConnectionService({
    required this.localNodeId,
    required this.port,
    required this.registry,
    required this.metrics,
    required this.serviceUuid,
    this.maxConnections,
    int? targetConnections,
    this.onLog,
    bool Function(NodeId)? discoveryFilter,
    Clock? clock,
    Duration discoveryInterval = const Duration(seconds: 5),
  })  : targetConnections = targetConnections ?? maxConnections,
        _discoveryFilter = discoveryFilter,
        _clock = clock ?? const Clock(),
        _discoveryInterval = discoveryInterval {
    _portSub = port.events.listen(_onPortEvent);
  }

  final NodeId localNodeId;
  final BlueyPort port;
  final ConnectionRegistry registry;
  final BlueyMetrics metrics;
  final ServiceUuid serviceUuid;
  final int? maxConnections;
  final int? targetConnections;
  final LogCallback? onLog;
  // ignore: unused_field, prefer_final_fields
  bool Function(NodeId)? _discoveryFilter;
  final Clock _clock;
  // ignore: unused_field
  final Duration _discoveryInterval;

  late final StreamSubscription<BlueyPortEvent> _portSub;
  final StreamController<ConnectionEvent> _events =
      StreamController<ConnectionEvent>.broadcast();
  final StreamController<ConnectionError> _errors =
      StreamController<ConnectionError>.broadcast();
  final StreamController<IncomingMessage> _incoming =
      StreamController<IncomingMessage>.broadcast();
  final Map<NodeId, FrameDecoder> _decoders = {};

  Stream<ConnectionEvent> get events => _events.stream;
  Stream<ConnectionError> get errors => _errors.stream;

  @override
  Stream<IncomingMessage> get incomingMessages => _incoming.stream;

  void _onPortEvent(BlueyPortEvent event) {
    switch (event) {
      case PortPeerConnected(:final nodeId, :final role, :final displayName):
        final handle = ConnectionHandle(
          nodeId: nodeId,
          role: role,
          displayName: displayName,
          connectedAt: _clock.now(),
        );
        registry.add(handle);
        _decoders[nodeId] = FrameDecoder();
        metrics.recordConnectionEstablished();
        metrics.setConnectedPeerCount(registry.connectionCount);
        _events.add(PeerOpened(nodeId: nodeId, displayName: displayName));
      case PortPeerDisconnected(:final nodeId, :final reason):
        final removed = registry.remove(nodeId);
        _decoders.remove(nodeId);
        metrics.setConnectedPeerCount(registry.connectionCount);
        if (removed != null) {
          _events.add(PeerClosed(nodeId: nodeId, reason: reason));
        }
      case PortPeerData(:final nodeId, :final data):
        final decoder = _decoders[nodeId];
        if (decoder == null) {
          // Data from a peer we don't know about — ignore.
          return;
        }
        metrics.recordFrameReceived();
        metrics.recordBytesReceived(data.length);
        try {
          final messages = decoder.feed(data);
          for (final m in messages) {
            metrics.recordMessageReceived();
            _incoming.add(IncomingMessage(
              sender: nodeId,
              bytes: m,
              receivedAt: _clock.now(),
            ));
          }
        } on FormatException catch (e) {
          _errors.add(FrameDecodeError(
            message: e.message,
            occurredAt: _clock.now(),
            nodeId: nodeId,
          ));
          // Tear down the connection on decode failure.
          unawaited(port.disconnect(nodeId));
        }
      case PortConnectFailed():
        // handled in Task 24
        break;
    }
  }

  @override
  Future<void> sendGossipMessage(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
    // Filled in Task 18.
    throw UnimplementedError();
  }

  @override
  int pendingSendCount(NodeId peer) => 0;

  @override
  int get totalPendingSendCount => 0;

  @override
  Future<void> close() async => dispose();

  Future<void> dispose() async {
    await _portSub.cancel();
    await _events.close();
    await _errors.close();
    await _incoming.close();
  }
}
