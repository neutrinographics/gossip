import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../domain/aggregates/connection_registry.dart';
import '../../domain/entities/connection_handle.dart';
import '../../domain/errors/connection_error.dart';
import '../../domain/events/connection_event.dart';
import '../../domain/interfaces/bluey_port.dart';
import '../../domain/value_objects/ble_address.dart';
import '../../domain/value_objects/scan_candidate.dart';
import '../../infrastructure/codec/frame_codec.dart';
import '../../infrastructure/ports/bluey_message_port.dart';
import '../observability/bluey_metrics.dart';

/// Trivial clock seam for tests.
class Clock {
  const Clock();
  DateTime now() => DateTime.now();
}

/// Owns the active-connection registry, frame decoders, per-peer send
/// queue, and the subscription to [BlueyPort] events. Does NOT own the
/// scan subscription nor make auto-connect decisions; those live in
/// `DiscoveryService` and `AutoConnectPolicy` respectively.
///
/// To establish a new connection, callers (manual mode) or
/// `AutoConnectPolicy` (auto mode) invoke [connectTo].
class ConnectionManager implements MessageDispatcher {
  ConnectionManager({
    required this.port,
    required this.registry,
    required this.metrics,
    this.maxConnections,
    this.onLog,
    Clock? clock,
  }) : _clock = clock ?? const Clock() {
    _portSub = port.events.listen(_onPortEvent);
  }

  final BlueyPort port;
  final ConnectionRegistry registry;
  final BlueyMetrics metrics;
  final int? maxConnections;
  final LogCallback? onLog;
  final Clock _clock;

  /// Addresses with an in-flight [connectTo] call. Used to guard against
  /// reentrant [connectTo] for the same address.
  final Set<BleAddress> _connectingAddresses = {};

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

  /// Initiate a connection to [candidate]. The candidate's address is
  /// passed through to [BlueyPort.connectAndIdentify], which performs the
  /// GATT-level connect plus Bluey-protocol identification and returns
  /// the resolved [NodeId]. The caller can then send to that NodeId.
  ///
  /// Reentrancy-protected via [_connectingAddresses]: a second call for
  /// the same address while one is in flight throws [StateError].
  ///
  /// Does NOT add backoff or dedup against the connection registry; those
  /// are the responsibility of `AutoConnectPolicy` in auto mode. In
  /// manual mode the consumer makes the policy decision.
  Future<NodeId> connectTo(ScanCandidate candidate) async {
    if (_connectingAddresses.contains(candidate.address)) {
      throw StateError('already connecting to ${candidate.address}');
    }
    _connectingAddresses.add(candidate.address);
    try {
      return await port.connectAndIdentify(candidate);
    } finally {
      _connectingAddresses.remove(candidate.address);
    }
  }

  void _onPortEvent(BlueyPortEvent event) {
    switch (event) {
      case PortPeerConnected(
        :final nodeId,
        :final role,
        :final address,
        :final displayName,
      ):
        if (maxConnections != null &&
            registry.connectionCount >= maxConnections!) {
          _errors.add(
            ConnectionLimitReachedError(
              message: 'rejected $nodeId: at maxConnections',
              occurredAt: _clock.now(),
              nodeId: nodeId,
            ),
          );
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
            metrics.recordConnectionEstablished();
            metrics.setConnectedPeerCount(registry.connectionCount);
            _events.add(
              PeerOpened(
                nodeId: nodeId,
                address: address,
                displayName: displayName,
              ),
            );
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
        final result = decoder.feed(data);
        if (result.bytesDiscarded > 0) {
          metrics.recordFrameRecovery(result.bytesDiscarded);
          onLog?.call(
            LogLevel.warning,
            'frame decoder recovered from corruption on $nodeId; '
            'discarded ${result.bytesDiscarded} bytes',
          );
        }
        for (final m in result.messages) {
          metrics.recordMessageReceived();
          _incoming.add(
            IncomingMessage(sender: nodeId, bytes: m, receivedAt: _clock.now()),
          );
        }
      case PortConnectFailed():
        // TODO(C4): forward to AutoConnectPolicy backoff bookkeeping
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
      _errors.add(
        ConnectionNotFoundError(
          message: 'no active connection to $destination',
          occurredAt: _clock.now(),
          nodeId: destination,
        ),
      );
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
      _errors.add(
        ConnectionNotFoundError(
          message: 'no active connection to $destination',
          occurredAt: _clock.now(),
          nodeId: destination,
        ),
      );
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
        _errors.add(
          SendFailedError(
            message: 'send failed to $destination',
            occurredAt: _clock.now(),
            nodeId: destination,
            cause: e,
          ),
        );
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

  /// Initiates a local disconnect for [nodeId]. Returns when the
  /// platform-level disconnect call has been issued; the registry entry
  /// is removed via the resulting `PortPeerDisconnected` event handler.
  Future<void> disconnect(NodeId nodeId) => port.disconnect(nodeId);

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
    _connectingAddresses.clear();
    _sendQueue.clear();
    await _portSub.cancel();
    await _events.close();
    await _errors.close();
    await _incoming.close();
  }
}
