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

  /// Per-peer send queue. Each peer's chunked sends are serialized so
  /// concurrent `sendGossipMessage` calls to the same peer don't
  /// interleave their chunks on the wire (which would corrupt the
  /// receiver's FrameDecoder byte-stream alignment).
  final Map<NodeId, Future<void>> _sendQueue = {};

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
        switch (registry.tryRegister(handle)) {
          case DuplicateRejected():
            onLog?.call(
              LogLevel.info,
              'duplicate connection for $nodeId arrived as $role; dropping',
            );
            unawaited(port.disconnectRole(nodeId, role));
            return;
          case Registered():
            _decoders[nodeId] = FrameDecoder();
            _backoff.remove(nodeId);
            metrics.recordConnectionEstablished();
            metrics.setConnectedPeerCount(registry.connectionCount);
            _events.add(PeerOpened(nodeId: nodeId, displayName: displayName));
        }
      case PortPeerDisconnected(:final nodeId, :final role, :final reason):
        // The registry only holds one handle per NodeId regardless of
        // role. When a disconnect arrives, it may be for the role we
        // registered (the "real" link) OR for a duplicate role we
        // race-rejected (which never made it into the registry).
        // Only act if the disconnected role matches the registered one;
        // otherwise the duplicate's teardown is just bookkeeping and
        // must not unregister the active link.
        final existing = registry.get(nodeId);
        if (existing == null || existing.role != role) {
          return;
        }
        registry.remove(nodeId);
        _decoders.remove(nodeId);
        // Drop any in-flight send chain. The chain's Future will
        // resolve on its own; we just stop tracking it for new sends.
        // sendGossipMessage will see registry.contains(...) == false
        // on its next dispatch and fail cleanly.
        unawaited(_sendQueue.remove(nodeId) ?? Future<void>.value());
        metrics.setConnectedPeerCount(registry.connectionCount);
        _events.add(PeerClosed(nodeId: nodeId, reason: reason));
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
    // Chain this send behind the previous send to the same peer so
    // chunked frames don't interleave on the wire. Without this,
    // concurrent calls each get their own for-loop and the receiver's
    // FrameDecoder loses byte-stream alignment.
    final previous = _sendQueue[destination] ?? Future<void>.value();
    final task = previous
        .catchError((_) {})
        .then((_) => _sendChunked(destination, bytes));
    _sendQueue[destination] = task;
    try {
      await task;
    } finally {
      // Drop the entry only if we're still the tail. A later send may
      // have chained behind us; that one becomes the new tail.
      if (identical(_sendQueue[destination], task)) {
        _sendQueue.remove(destination);
      }
    }
  }

  Future<void> _sendChunked(NodeId destination, Uint8List bytes) async {
    if (!registry.contains(destination)) {
      // Connection dropped while we were queued behind a previous send.
      _errors.add(ConnectionNotFoundError(
        message: 'no active connection to $destination',
        occurredAt: _clock.now(),
        nodeId: destination,
      ));
      return;
    }
    final chunks = FrameEncoder.encode(
      bytes,
      mtuPayloadSize: port.chunkSizeFor(destination),
    );
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
    _discoveryTimer = Timer(_discoveryInterval, () async {
      // Await the round before scheduling the next one. Otherwise a hung
      // discoverPeers (e.g. when bluey's iOS scan never returns) lets
      // subsequent rounds pile up and stack scan-starts on the BLE
      // adapter, which on Android trips "scanning too frequently"
      // throttling.
      await _runDiscoveryRound();
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
    onLog?.call(
      LogLevel.debug,
      'discovery round: found ${peers.length} peer(s)'
      '${peers.isEmpty ? '' : ' [${peers.map((p) => p.nodeId.value).join(', ')}]'}',
    );
    for (final p in peers) {
      if (registry.contains(p.nodeId)) {
        onLog?.call(
          LogLevel.debug,
          'discovery: skipping ${p.nodeId} (already connected)',
        );
        continue;
      }
      if (_discoveryFilter != null && !_discoveryFilter!(p.nodeId)) {
        onLog?.call(
          LogLevel.debug,
          'discovery: skipping ${p.nodeId} (filtered out)',
        );
        continue;
      }
      // Tie-break: only initiate if our nodeId < remote.
      if (localNodeId.value.compareTo(p.nodeId.value) >= 0) {
        onLog?.call(
          LogLevel.debug,
          'discovery: skipping ${p.nodeId} (tie-break: peer initiates)',
        );
        continue;
      }
      if (targetConnections != null &&
          registry.connectionCount >= targetConnections!) {
        onLog?.call(
          LogLevel.debug,
          'discovery: stopping further initiations (at targetConnections)',
        );
        return;
      }
      final entry = _backoff[p.nodeId];
      if (entry != null && _clock.now().isBefore(entry.nextAttempt)) {
        onLog?.call(
          LogLevel.debug,
          'discovery: skipping ${p.nodeId} (in backoff window, retry at ${entry.nextAttempt})',
        );
        continue;
      }
      onLog?.call(LogLevel.info, 'discovery: initiating connect to ${p.nodeId}');
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
    _sendQueue.clear();
    await _portSub.cancel();
    await _events.close();
    await _errors.close();
    await _incoming.close();
  }
}
