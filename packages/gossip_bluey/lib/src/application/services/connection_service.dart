import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../domain/aggregates/connection_registry.dart';
import '../../domain/entities/connection_handle.dart';
import '../../domain/errors/connection_error.dart';
import '../../domain/errors/not_a_bluey_peer_exception.dart';
import '../../domain/events/connection_event.dart';
import '../../domain/interfaces/bluey_port.dart';
import '../../domain/value_objects/ble_address.dart';
import '../../domain/value_objects/scan_candidate.dart';
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
    @Deprecated(
      'No-op since the scan-upgrade migration; scan is now '
      'long-lived and does not run on a fixed interval.',
    )
    Duration discoveryInterval = const Duration(seconds: 5),
  }) : targetConnections = targetConnections ?? maxConnections,
       _discoveryFilter = discoveryFilter,
       _clock = clock ?? const Clock() {
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
  bool _discoveryEnabled = false;

  // Cancelled in [stopDiscovery] and [dispose].
  // ignore: cancel_subscriptions
  StreamSubscription<ScanCandidate>? _scanSub;
  final Set<BleAddress> _connectingAddresses = {};
  final Map<BleAddress, NodeId> _addressToNodeId = {};

  static const _initialBackoff = Duration(seconds: 1);
  static const _maxBackoff = Duration(seconds: 30);
  static const _addressLongBackoff = Duration(minutes: 5);
  final Map<BleAddress, ({Duration delay, DateTime nextAttempt})>
  _addressBackoff = {};

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
            // Populate the address cache so subsequent scan emissions
            // for this peer (in the inverse role) are silenced
            // pre-connect. Critical on iOS where calling connectAsPeer
            // for a device already held in the inverse role triggers
            // CoreBluetooth's peer-merge tear-down.
            _addressToNodeId[address] = nodeId;
            _decoders[nodeId] = FrameDecoder();
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
            IncomingMessage(
              sender: nodeId,
              bytes: m,
              receivedAt: _clock.now(),
            ),
          );
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

  Future<void> startDiscovery({bool Function(NodeId)? filter}) async {
    if (filter != null) {
      _discoveryFilter = filter;
    }
    if (_scanSub != null) return;
    _discoveryEnabled = true;
    _scanSub = port
        .scanForCandidates(serviceUuid: serviceUuid)
        .listen(_onCandidate);
  }

  Future<void> stopDiscovery() async {
    _discoveryEnabled = false;
    final sub = _scanSub;
    _scanSub = null;
    await sub?.cancel();
    await port.stopScan();
  }

  Future<void> _onCandidate(ScanCandidate c) async {
    if (!_discoveryEnabled) return;
    if (_connectingAddresses.contains(c.address)) return;

    // Pre-connect dedup: if we've already learned this address's NodeId
    // from a prior connect, and that NodeId is still in the registry,
    // silence repeated scan emissions.
    final knownNode = _addressToNodeId[c.address];
    if (knownNode != null && registry.contains(knownNode)) return;

    final backoffEntry = _addressBackoff[c.address];
    if (backoffEntry != null &&
        _clock.now().isBefore(backoffEntry.nextAttempt)) {
      return;
    }
    if (targetConnections != null &&
        registry.connectionCount >= targetConnections!) {
      return;
    }

    _connectingAddresses.add(c.address);
    try {
      final nodeId = await port.connectAndIdentify(c);
      _addressToNodeId[c.address] = nodeId;
      _addressBackoff.remove(c.address);

      if (_discoveryFilter != null && !_discoveryFilter!(nodeId)) {
        onLog?.call(
          LogLevel.debug,
          'candidate $nodeId filtered; disconnecting',
        );
        unawaited(port.disconnectRole(nodeId, ConnectionRole.central));
      }
    } on NotABlueyPeerException {
      onLog?.call(
        LogLevel.debug,
        'candidate ${c.address} is not a bluey peer; long backoff',
      );
      _addressBackoff[c.address] = (
        delay: _addressLongBackoff,
        nextAttempt: _clock.now().add(_addressLongBackoff),
      );
    } catch (e, st) {
      onLog?.call(
        LogLevel.warning,
        'connectAndIdentify failed for ${c.address}',
        e,
        st,
      );
      final prev = _addressBackoff[c.address]?.delay ?? Duration.zero;
      final next = prev == Duration.zero
          ? _initialBackoff
          : Duration(
              milliseconds: (prev.inMilliseconds * 2).clamp(
                _initialBackoff.inMilliseconds,
                _maxBackoff.inMilliseconds,
              ),
            );
      _addressBackoff[c.address] = (
        delay: next,
        nextAttempt: _clock.now().add(next),
      );
      metrics.recordConnectionFailed();
    } finally {
      _connectingAddresses.remove(c.address);
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
    _discoveryEnabled = false;
    final scanSub = _scanSub;
    _scanSub = null;
    await scanSub?.cancel();
    _addressBackoff.clear();
    _addressToNodeId.clear();
    _connectingAddresses.clear();
    _sendQueue.clear();
    await _portSub.cancel();
    await _events.close();
    await _errors.close();
    await _incoming.close();
  }
}
