import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../domain/aggregates/connection_registry.dart';
import '../../domain/entities/connection_handle.dart';
import '../../domain/errors/already_connecting_exception.dart';
import '../../domain/errors/connection_error.dart';
import '../../domain/errors/connection_rejected_exception.dart';
import '../../domain/events/connection_event.dart';
import '../../domain/interfaces/bluey_port.dart';
import '../../domain/value_objects/ble_address.dart';
import '../../domain/value_objects/scan_candidate.dart';
import '../../infrastructure/codec/control_frame_codec.dart';
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
    required this.localNodeId,
    this.maxConnections,
    this.onLog,
    this.sendTimeout = defaultSendTimeout,
    Clock? clock,
  }) : _clock = clock ?? const Clock() {
    _portSub = port.events.listen(
      _onPortEvent,
      // A port stream error must reach the logging surface instead of
      // escaping as an uncaught zone error.
      onError: (Object e, StackTrace st) {
        onLog?.call(LogLevel.error, 'port event stream error', e, st);
      },
    );
  }

  /// Default upper bound on a single chunk write ([BlueyPort.sendData]).
  ///
  /// Deliberately generous — a single BLE chunk write normally completes
  /// in milliseconds. The point is to unwedge the peer's drain loop when
  /// a GATT write hangs (platform bug, dead link the state watcher never
  /// noticed), not to race normal writes: without a bound, one hung write
  /// blocks every queued message to that peer forever, including
  /// high-priority SWIM pings.
  static const Duration defaultSendTimeout = Duration(seconds: 30);

  final BlueyPort port;
  final ConnectionRegistry registry;
  final BlueyMetrics metrics;

  /// This device's own identity — the tie-break (Task 3) compares it
  /// against the remote NodeId to pick the surviving link in a mutual
  /// connect.
  final NodeId localNodeId;
  final int? maxConnections;
  final LogCallback? onLog;

  /// Per-chunk write timeout; a timed-out chunk is treated exactly like a
  /// failed chunk write (SendFailedError, message aborted, link torn down).
  final Duration sendTimeout;

  final Clock _clock;

  /// Addresses with an in-flight [connectTo] call. Used to guard against
  /// reentrant [connectTo] for the same address.
  final Set<BleAddress> _connectingAddresses = {};

  /// Per-peer, two-lane (high/normal) send queue.
  ///
  /// Each peer's chunked sends are serialized so concurrent
  /// `sendGossipMessage` calls to the same peer don't interleave their
  /// chunks on the wire (which would corrupt the receiver's FrameDecoder
  /// byte-stream alignment). Within a peer, the high-priority lane (SWIM
  /// pings/acks) drains ahead of the normal lane (bulk gossip) so failure
  /// detection isn't delayed behind a large delta during congestion.
  ///
  /// Queues are per-peer — not one global queue like `gossip_nearby`'s
  /// transport — because each peer is an independent framed link: sends
  /// to different peers may proceed concurrently, but a single peer's
  /// frame stream must stay contiguous.
  final Map<NodeId, _PeerSendQueue> _sendQueues = {};

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

  // Emissions guarded against closed controllers: an in-flight send or a
  // late port event failing AFTER dispose() must not throw StateError
  // into its awaiter.
  void _emitError(ConnectionError error) {
    if (!_errors.isClosed) _errors.add(error);
  }

  void _emitEvent(ConnectionEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _emitIncoming(IncomingMessage message) {
    if (!_incoming.isClosed) _incoming.add(message);
  }

  @override
  Stream<IncomingMessage> get incomingMessages => _incoming.stream;

  /// Initiate a connection to [candidate]. The candidate's address is
  /// passed through to [BlueyPort.connectAndIdentify], which performs the
  /// GATT-level connect plus Bluey-protocol identification and returns
  /// the resolved [NodeId]. When this future resolves, the connection is
  /// registered — the caller can send to that NodeId immediately.
  ///
  /// Reentrancy-protected via [_connectingAddresses]: a second call for
  /// the same address while one is in flight throws
  /// [AlreadyConnectingException] (a typed exception so policies can
  /// distinguish it from real connect failures).
  ///
  /// Throws [ConnectionRejectedException] when the connect and
  /// identification succeeded but the connection was NOT registered
  /// (maxConnections cap, duplicate NodeId) — success would hand the
  /// caller a NodeId it can never send to.
  ///
  /// Does NOT add backoff or dedup against the connection registry; those
  /// are the responsibility of `AutoConnectPolicy` in auto mode. In
  /// manual mode the consumer makes the policy decision.
  Future<NodeId> connectTo(ScanCandidate candidate) async {
    if (_connectingAddresses.contains(candidate.address)) {
      throw AlreadyConnectingException(candidate.address);
    }
    _connectingAddresses.add(candidate.address);
    try {
      final nodeId = await port.connectAndIdentify(candidate);
      // The PortPeerConnected event is dispatched asynchronously on the
      // port's broadcast stream; wait (bounded) until the registry
      // reflects it so a caller that sends immediately doesn't get
      // ConnectionNotFoundError despite the connect having succeeded.
      for (var i = 0; i < 16 && !registry.contains(nodeId); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      if (!registry.contains(nodeId)) {
        throw ConnectionRejectedException(nodeId);
      }
      return nodeId;
    } finally {
      _connectingAddresses.remove(candidate.address);
    }
  }

  void _onPortEvent(BlueyPortEvent event) {
    // Contained: a throw from one event's handling must not surface as an
    // uncaught zone error nor poison the processing of later events.
    try {
      _handlePortEvent(event);
    } catch (e, st) {
      onLog?.call(LogLevel.error, 'error handling port event $event', e, st);
    }
  }

  void _handlePortEvent(BlueyPortEvent event) {
    switch (event) {
      case PortPeerConnected(
        :final nodeId,
        :final role,
        :final address,
        :final displayName,
      ):
        // Duplicate check BEFORE the cap check: a duplicate role for an
        // already-registered peer doesn't consume a slot, and letting it
        // hit the cap branch would tear down the ACTIVE link via a
        // role-blind disconnect.
        final existing = registry.get(nodeId);
        if (existing != null) {
          if (existing.role == role) {
            // Same-role duplicate: a reconnect race, not a mutual
            // connect. Keep first-write-wins; the port layer's
            // supersession handles genuine link replacement (COR3-5).
            onLog?.call(
              LogLevel.info,
              'duplicate $role connection for $nodeId; dropping newcomer',
            );
            _disconnectRoleGuarded(nodeId, role);
            return;
          }
          // Mutual connect: we now hold one central and one peripheral
          // link to the same peer. Tie-break (COR3-29): the surviving
          // link is the one whose CENTRAL is the lexicographically
          // smaller NodeId — the loser closes its own central, which is
          // physically the same link as the winner's peripheral, so the
          // pair converges to exactly one link with no peripheral-side
          // disconnect API.
          final localWins = localNodeId.value.compareTo(nodeId.value) < 0;
          final survivingLocalRole =
              localWins ? ConnectionRole.central : ConnectionRole.peripheral;
          if (existing.role == survivingLocalRole) {
            // Registered link survives; shed the newcomer. If the
            // newcomer is our central we close it for real; if it is our
            // peripheral this marks it rejected and the remote (the
            // loser there) closes it physically.
            onLog?.call(
              LogLevel.info,
              'tie-break for $nodeId: keeping ${existing.role} link, '
              'shedding new $role link',
            );
            _disconnectRoleGuarded(nodeId, role);
            return;
          }
          // The NEW link survives: swap the registration in place. The
          // peer never disconnected at NodeId level, so no PeerClosed/
          // PeerOpened — consumers see continuous connectivity. A fresh
          // decoder isolates the new link's byte stream; residue from
          // the dying link is absorbed by the decoder's garbage
          // recovery.
          onLog?.call(
            LogLevel.info,
            'tie-break for $nodeId: adopting new $role link, '
            'closing ${existing.role} link',
          );
          registry.remove(nodeId);
          registry.tryRegister(
            ConnectionHandle(
              nodeId: nodeId,
              role: role,
              displayName: displayName,
              connectedAt: _clock.now(),
            ),
          );
          _decoders[nodeId] = FrameDecoder();
          _disconnectRoleGuarded(nodeId, existing.role);
          return;
        }
        if (maxConnections != null &&
            registry.connectionCount >= maxConnections!) {
          _emitError(
            ConnectionLimitReachedError(
              message: 'rejected $nodeId: at maxConnections',
              occurredAt: _clock.now(),
              nodeId: nodeId,
            ),
          );
          if (role == ConnectionRole.peripheral) {
            // We cannot close an inbound peripheral link (no per-client
            // disconnect API) — tell the remote central to close it
            // (COR3-21). Best-effort single shot: on failure we are no
            // worse off than before the frame existed.
            unawaited(
              port
                  .sendData(
                    nodeId,
                    ControlFrameCodec.encodeRejection(RejectionReason.capacity),
                  )
                  .catchError((Object e, StackTrace st) {
                onLog?.call(
                  LogLevel.warning,
                  'rejection frame to $nodeId failed',
                  e,
                  st,
                );
              }),
            );
          }
          // Tear down exactly the role that just connected — never the
          // role-blind disconnect(), which prefers central and could hit
          // an unrelated link.
          _disconnectRoleGuarded(nodeId, role);
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
            // Unreachable in practice (contains() checked above) but the
            // registry contract requires handling it.
            _disconnectRoleGuarded(nodeId, role);
            return;
          case Registered():
            _decoders[nodeId] = FrameDecoder();
            metrics.recordConnectionEstablished();
            metrics.setConnectedPeerCount(registry.connectionCount);
            _emitEvent(
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
        // Leave the peer's send queue in place: its drain loop owns the
        // map entry and removes it once emptied. Any in-flight send
        // aborts via the per-chunk `identical(registry.get, handle)`
        // check in `_sendChunked`, and queued sends fail cleanly (the
        // registry entry is gone). Removing the entry here instead would
        // risk a second drain loop for the same peer on a fast reconnect,
        // interleaving two messages' chunks on one link.
        metrics.setConnectedPeerCount(registry.connectionCount);
        _emitEvent(PeerClosed(nodeId: nodeId, reason: reason));
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
          _emitIncoming(
            IncomingMessage(sender: nodeId, bytes: m, receivedAt: _clock.now()),
          );
        }
      case PortConnectFailed(:final nodeId, :final reason):
        metrics.recordConnectionFailed();
        onLog?.call(
          LogLevel.info,
          'connect to $nodeId failed: $reason',
        );
    }
  }

  @override
  Future<void> sendGossipMessage(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) {
    if (!registry.contains(destination)) {
      _emitError(
        ConnectionNotFoundError(
          message: 'no active connection to $destination',
          occurredAt: _clock.now(),
          nodeId: destination,
        ),
      );
      return Future<void>.value();
    }
    // Enqueue on the peer's high or normal lane, then ensure its drain
    // loop is running. The loop serializes this peer's chunked sends
    // (no frame interleaving) and drains high-priority ahead of normal.
    final queue = _sendQueues.putIfAbsent(destination, _PeerSendQueue.new);
    final queued = _QueuedSend(bytes);
    if (priority == MessagePriority.high) {
      queue.high.add(queued);
    } else {
      queue.normal.add(queued);
    }
    unawaited(_drainQueue(destination, queue));
    return queued.completer.future;
  }

  /// Drains a peer's send queue — high-priority lane first — one whole
  /// message at a time. Only one loop runs per peer (guarded by
  /// [_PeerSendQueue.processing]).
  ///
  /// A message's chunks are sent contiguously via [_sendChunked], so a
  /// high-priority message can jump ahead of *queued* messages but never
  /// preempts one already mid-transmission — interleaving two messages'
  /// frames on a single link would corrupt the receiver's decoder. This
  /// still bounds a ping's wait to at most one in-flight delta instead of
  /// the whole backlog.
  Future<void> _drainQueue(NodeId destination, _PeerSendQueue queue) async {
    if (queue.processing) return;
    queue.processing = true;
    try {
      while (!queue.isEmpty) {
        final next = queue.removeNext();
        try {
          await _sendChunked(destination, next.bytes);
          if (!next.completer.isCompleted) next.completer.complete();
        } catch (e, st) {
          // A known-failed send must complete with an error, never
          // success: the MessagePort contract lets the core engine roll
          // back optimistic state (pending-request flags) immediately
          // instead of waiting out a timeout. Later queued messages
          // still drain.
          if (!next.completer.isCompleted) next.completer.completeError(e, st);
        }
      }
    } finally {
      queue.processing = false;
      // Reclaim the entry once drained, but only if we're still the
      // tracked queue for this peer (defensive against replacement).
      if (queue.isEmpty && identical(_sendQueues[destination], queue)) {
        _sendQueues.remove(destination);
      }
    }
  }

  /// Sends one whole message as contiguous frame chunks. Throws on any
  /// failure — the caller ([_drainQueue]) completes the message's future
  /// with the thrown error — after emitting the matching
  /// [ConnectionError] on [errors] for observability.
  Future<void> _sendChunked(NodeId destination, Uint8List bytes) async {
    final handle = registry.get(destination);
    if (handle == null) {
      // Connection dropped while we were queued behind a previous send.
      final error = ConnectionNotFoundError(
        message: 'no active connection to $destination',
        occurredAt: _clock.now(),
        nodeId: destination,
      );
      _emitError(error);
      throw error;
    }
    final chunks = FrameEncoder.encode(
      bytes,
      mtuPayloadSize: port.chunkSizeFor(destination),
    );
    for (final chunk in chunks) {
      // Re-check per chunk against the SAME handle: a disconnect + fast
      // reconnect mid-message swaps the registry entry, and writing this
      // frame's remaining chunks to the new link would corrupt the
      // receiver's byte-stream alignment.
      if (!identical(registry.get(destination), handle)) {
        final error = SendFailedError(
          message:
              'send to $destination aborted: connection replaced '
              'mid-message',
          occurredAt: _clock.now(),
          nodeId: destination,
        );
        _emitError(error);
        throw error;
      }
      try {
        // Bounded per chunk: a hung GATT write (dead link the state
        // watcher never noticed) must not wedge this peer's drain loop
        // forever. A timeout is handled exactly like a failed write.
        await port.sendData(destination, chunk).timeout(sendTimeout);
        metrics.recordFrameSent();
        metrics.recordBytesSent(chunk.length);
      } catch (e, st) {
        _emitError(
          SendFailedError(
            message: 'send failed to $destination',
            occurredAt: _clock.now(),
            nodeId: destination,
            cause: e,
          ),
        );
        onLog?.call(LogLevel.warning, 'send failed', e, st);
        // Tear down only the link this send was using — if it was
        // already replaced, the new connection is innocent.
        if (identical(registry.get(destination), handle)) {
          _disconnectRoleGuarded(destination, handle.role);
        }
        rethrow;
      }
    }
    metrics.recordMessageSent();
  }

  /// Fire-and-forget role-specific disconnect with error containment.
  ///
  /// `port.disconnectRole` can throw (e.g. BluetoothUnavailableException
  /// when the adapter turned off); an unhandled failed future from
  /// `unawaited(...)` would surface as an uncaught zone error.
  void _disconnectRoleGuarded(NodeId nodeId, ConnectionRole role) {
    unawaited(
      port.disconnectRole(nodeId, role).catchError((Object e, StackTrace st) {
        onLog?.call(LogLevel.warning, 'disconnectRole($nodeId, $role) failed', e, st);
      }),
    );
  }

  @override
  int pendingSendCount(NodeId peer) => _sendQueues[peer]?.length ?? 0;

  @override
  int get totalPendingSendCount =>
      _sendQueues.values.fold(0, (sum, q) => sum + q.length);

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
    // Fail any still-queued sends so their awaiters don't hang past
    // dispose — with an ERROR, not success: these messages were never
    // written and the MessagePort contract forbids reporting a
    // known-failed send as delivered. An in-flight message (already
    // dequeued) is resolved by its own drain loop.
    for (final entry in _sendQueues.entries) {
      final queue = entry.value;
      while (!queue.isEmpty) {
        final s = queue.removeNext();
        if (s.completer.isCompleted) continue;
        // Mark the error handled before completing: a fire-and-forget
        // caller may never await this future, and an unobserved error
        // would surface as an uncaught zone error. Real awaiters still
        // receive it.
        unawaited(s.completer.future.catchError((_) {}));
        s.completer.completeError(
          SendFailedError(
            message: 'send to ${entry.key} dropped: transport disposed',
            occurredAt: _clock.now(),
            nodeId: entry.key,
          ),
          StackTrace.current,
        );
      }
    }
    _sendQueues.clear();
    _decoders.clear();
    await _portSub.cancel();
    await _events.close();
    await _errors.close();
    await _incoming.close();
  }
}

/// A single gossip message waiting in a peer's send queue, with a
/// completer resolved with success once the message has been handed to
/// the transport, or with an error when the send is known to have failed
/// (MessagePort contract).
class _QueuedSend {
  _QueuedSend(this.bytes);

  final Uint8List bytes;
  final Completer<void> completer = Completer<void>();
}

/// Two-lane (high/normal) FIFO send queue for one peer, plus a
/// re-entrancy flag so only one drain loop runs at a time.
class _PeerSendQueue {
  final Queue<_QueuedSend> high = Queue<_QueuedSend>();
  final Queue<_QueuedSend> normal = Queue<_QueuedSend>();
  bool processing = false;

  bool get isEmpty => high.isEmpty && normal.isEmpty;

  int get length => high.length + normal.length;

  /// Removes the next message to send: high-priority lane first.
  /// Caller must ensure the queue is non-empty.
  _QueuedSend removeNext() =>
      high.isNotEmpty ? high.removeFirst() : normal.removeFirst();
}
