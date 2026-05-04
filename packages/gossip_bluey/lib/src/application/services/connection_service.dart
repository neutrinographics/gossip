import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../domain/aggregates/connection_registry.dart';
import '../../domain/entities/connection_handle.dart';
import '../../domain/errors/connection_error.dart';
import '../../domain/events/connection_event.dart';
import '../../domain/interfaces/bluey_port.dart';
import '../../domain/value_objects/discovered_peer.dart';
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
  // ignore: prefer_final_fields
  bool Function(NodeId)? _discoveryFilter;
  final Clock _clock;
  final Duration _discoveryInterval;
  bool _discoveryEnabled = false;
  Timer? _discoveryTimer;

  static const _initialBackoff = Duration(seconds: 1);
  static const _maxBackoff = Duration(seconds: 30);
  final Map<NodeId, ({Duration delay, DateTime nextAttempt})> _backoff = {};

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
        if (maxConnections != null &&
            registry.connectionCount >= maxConnections!) {
          _errors.add(ConnectionLimitReachedError(
            message: 'rejected $nodeId: at maxConnections',
            occurredAt: _clock.now(),
            nodeId: nodeId,
          ));
          unawaited(port.disconnect(nodeId));
          return;
        }
        final handle = ConnectionHandle(
          nodeId: nodeId,
          role: role,
          displayName: displayName,
          connectedAt: _clock.now(),
        );
        registry.add(handle);
        _decoders[nodeId] = FrameDecoder();
        _backoff.remove(nodeId);
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
    if (!registry.contains(destination)) {
      _errors.add(ConnectionNotFoundError(
        message: 'no active connection to $destination',
        occurredAt: _clock.now(),
        nodeId: destination,
      ));
      return;
    }
    final chunks = FrameEncoder.encode(bytes, mtuPayloadSize: _effectiveMtu);
    for (final chunk in chunks) {
      try {
        await port.sendData(destination, chunk);
        metrics.recordFrameSent();
        metrics.recordBytesSent(chunk.length);
      } catch (e, st) {
        _errors.add(SendFailedError(
          message: 'send failed to $destination',
          occurredAt: _clock.now(),
          nodeId: destination,
          cause: e,
        ));
        onLog?.call(LogLevel.warning, 'send failed', e, st);
        unawaited(port.disconnect(destination));
        return;
      }
    }
    metrics.recordMessageSent();
  }

  /// Effective per-chunk MTU. Conservative default of 20 bytes (default
  /// BLE MTU 23 minus 3-byte ATT header). Real port impl can override
  /// in a follow-up.
  int get _effectiveMtu => 20;

  @override
  int pendingSendCount(NodeId peer) => 0;

  @override
  int get totalPendingSendCount => 0;

  @override
  Future<void> close() async => dispose();

  Future<void> startDiscovery({bool Function(NodeId)? filter}) async {
    if (filter != null) {
      _discoveryFilter = filter;
    }
    _discoveryEnabled = true;
    _scheduleDiscovery();
  }

  Future<void> stopDiscovery() async {
    _discoveryEnabled = false;
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
  }

  void _scheduleDiscovery() {
    _discoveryTimer?.cancel();
    if (!_discoveryEnabled) return;
    _discoveryTimer = Timer(_discoveryInterval, () {
      unawaited(_runDiscoveryRound());
      _scheduleDiscovery();
    });
  }

  /// Synchronously triggers one discovery round. Test-only.
  Future<void> runDiscoveryRoundForTest() => _runDiscoveryRound();

  Future<void> _runDiscoveryRound() async {
    if (!_discoveryEnabled) return;
    // Adaptive discovery: skip the scan entirely while at target.
    if (targetConnections != null &&
        registry.connectionCount >= targetConnections!) {
      return;
    }
    final List<DiscoveredPeer> peers;
    try {
      peers = await port.discoverPeers(serviceUuid: serviceUuid);
    } catch (e, st) {
      onLog?.call(LogLevel.warning, 'discoverPeers failed', e, st);
      return;
    }
    for (final p in peers) {
      if (registry.contains(p.nodeId)) continue;
      if (_discoveryFilter != null && !_discoveryFilter!(p.nodeId)) continue;
      // Tie-break: only initiate if our nodeId < remote.
      if (localNodeId.value.compareTo(p.nodeId.value) >= 0) continue;
      if (targetConnections != null &&
          registry.connectionCount >= targetConnections!) {
        return;
      }
      final entry = _backoff[p.nodeId];
      if (entry != null && _clock.now().isBefore(entry.nextAttempt)) {
        continue;
      }
      try {
        await port.connect(p.nodeId);
      } catch (e, st) {
        final prev = _backoff[p.nodeId]?.delay ?? Duration.zero;
        final nextDelay = prev == Duration.zero
            ? _initialBackoff
            : Duration(
                milliseconds: (prev.inMilliseconds * 2).clamp(
                  _initialBackoff.inMilliseconds,
                  _maxBackoff.inMilliseconds,
                ),
              );
        _backoff[p.nodeId] = (
          delay: nextDelay,
          nextAttempt: _clock.now().add(nextDelay),
        );
        metrics.recordConnectionFailed();
        _errors.add(ConnectFailedError(
          message: 'connect to ${p.nodeId} failed',
          occurredAt: _clock.now(),
          nodeId: p.nodeId,
          cause: e,
        ));
        onLog?.call(LogLevel.info, 'connect failed', e, st);
      }
    }
  }

  Future<void> disconnectAll() async {
    final ids = registry.connections.map((h) => h.nodeId).toList();
    for (final id in ids) {
      try {
        await port.disconnect(id);
      } catch (e, st) {
        onLog?.call(LogLevel.warning, 'disconnect failed for $id', e, st);
      }
    }
  }

  Future<void> dispose() async {
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _discoveryEnabled = false;
    _backoff.clear();
    await _portSub.cancel();
    await _events.close();
    await _errors.close();
    await _incoming.close();
  }
}
