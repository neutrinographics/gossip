import 'dart:async';

import 'package:gossip/gossip.dart';

import '../../domain/aggregates/connection_registry.dart';
import '../../domain/errors/already_connecting_exception.dart';
import '../../domain/errors/connection_error.dart';
import '../../domain/errors/connection_rejected_exception.dart';
import '../../domain/errors/not_a_bluey_peer_exception.dart';
import '../../domain/events/connection_event.dart';
import '../../domain/value_objects/ble_address.dart';
import '../../domain/value_objects/connection_mode.dart';
import '../../domain/value_objects/scan_candidate.dart';
import 'connection_manager.dart';
import 'discovery_service.dart';

/// Toggleable application service that, when in [ConnectionMode.auto],
/// subscribes to [DiscoveryService.candidates] and drives
/// [ConnectionManager.connectTo] per a backoff / dedup / target-cap
/// policy. In [ConnectionMode.manual] (the default) the policy is
/// dormant; the consumer must drive `connectTo` directly.
///
/// The policy does NOT duplicate [ConnectionManager]'s reentrancy
/// guard (the manager already protects against concurrent
/// `connectTo` for the same address); the policy's concerns are
/// per-address backoff, dedup against the connection registry, and
/// the optional target-connections cap.
class AutoConnectPolicy {
  AutoConnectPolicy({
    required DiscoveryService discovery,
    required ConnectionManager connections,
    required ConnectionRegistry registry,
    required DateTime Function() now,
    int? targetConnections,
    Duration initialBackoff = const Duration(seconds: 1),
    Duration maxBackoff = const Duration(seconds: 60),
    Duration longBackoff = const Duration(minutes: 10),
    this.onLog,
  })  : _discovery = discovery,
        _connections = connections,
        _registry = registry,
        _now = now,
        _targetConnections = targetConnections,
        _initialBackoff = initialBackoff,
        _maxBackoff = maxBackoff,
        _longBackoff = longBackoff {
    // A peer that rejected us (GSP2, e.g. at capacity) must not be
    // re-dialed at scan cadence: connectTo SUCCEEDED (clearing backoff)
    // before the rejection arrived, so without this hook the retry loop
    // would pace at scan speed against a still-full peer.
    _errorsSub = _connections.errors.listen(
      (error) {
        if (error is! ConnectionRejectedByPeerError) return;
        _recordRejectionBackoff(error.nodeId);
      },
      onError: (Object e, StackTrace st) {
        onLog?.call(LogLevel.warning, 'connection error stream error', e, st);
      },
    );
    // Radio duty-cycle (WIRE4-7): in auto mode with a target, a fully
    // connected node has nothing to gain from continuous scanning — the
    // single largest battery item on the transport. Rest discovery when
    // the target is reached; resume it when a peer is lost, because the
    // scan is then the recovery path.
    _eventsSub = _connections.events.listen(
      _onConnectionEvent,
      onError: (Object e, StackTrace st) {
        onLog?.call(LogLevel.warning, 'connection event stream error', e, st);
      },
    );
  }

  final DiscoveryService _discovery;
  final ConnectionManager _connections;
  final ConnectionRegistry _registry;
  final DateTime Function() _now;
  final int? _targetConnections;
  final Duration _initialBackoff;
  final Duration _maxBackoff;
  final Duration _longBackoff;
  final LogCallback? onLog;

  ConnectionMode _mode = ConnectionMode.manual;

  // Cancelled in [setMode]/[dispose].
  // ignore: cancel_subscriptions
  StreamSubscription<ScanCandidate>? _sub;

  // Cancelled in [dispose].
  // ignore: cancel_subscriptions
  StreamSubscription<ConnectionError>? _errorsSub;

  // Cancelled in [dispose].
  // ignore: cancel_subscriptions
  StreamSubscription<ConnectionEvent>? _eventsSub;

  void _onConnectionEvent(ConnectionEvent event) {
    final target = _targetConnections;
    if (target == null || _mode != ConnectionMode.auto) return;
    switch (event) {
      case PeerOpened():
        if (_registry.connectionCount >= target) {
          onLog?.call(
            LogLevel.info,
            'connection target ($target) reached; resting discovery',
          );
          unawaited(_discovery.stop());
        }
      case PeerClosed():
        if (_registry.connectionCount < target) {
          onLog?.call(
            LogLevel.info,
            'below connection target ($target); resuming discovery',
          );
          unawaited(_discovery.start());
        }
    }
  }

  /// Per-address backoff bookkeeping. `delay` is the current backoff
  /// window length (used to compute the next exponential step);
  /// `nextAttempt` is the wall-clock instant before which the policy
  /// must NOT call [ConnectionManager.connectTo] for this address.
  final Map<BleAddress, ({Duration delay, DateTime nextAttempt})> _backoff = {};

  /// Address → resolved NodeId cache. Once we've successfully
  /// identified a peer at an address, repeated scan emissions for that
  /// address are silenced as long as the NodeId is still in the
  /// connection registry.
  // TODO(post-Phase-D): On peer disconnect (PortPeerDisconnected event),
  // remove the entry here so the map doesn't grow unbounded across
  // address-rotation events (iOS MAC randomization, peer
  // rejoining with a fresh NodeId at an old address). At 8-peer scale
  // the growth is bounded and harmless; revisit if scale grows.
  final Map<BleAddress, NodeId> _knownAddressToNode = {};

  /// Per-NodeId memory of the last rejection-driven backoff, keyed by the
  /// *peer* rather than by address so it SURVIVES the `_backoff.remove`
  /// that a (transiently) successful connect performs in [_tryConnect].
  ///
  /// Without this, a peer that accepts our central link then rejects us
  /// via GSP2 every cycle would re-arm at [_initialBackoff] forever
  /// (connectTo succeeds → clears `_backoff` → the rejection hook reads a
  /// zeroed entry → records 1s again), so a newcomer redials a
  /// persistently-full peer with a full connect+identify+reject
  /// round-trip roughly every second.
  ///
  /// `delay` is the current window length; `activeUntil` is when it
  /// expires. A single rejection can surface as BOTH
  /// `ConnectionRejectedException` (connectTo threw mid-poll) and a
  /// `ConnectionRejectedByPeerError` on the errors stream — because a new
  /// connect attempt can only happen after the window expires, a second
  /// signal arriving while `activeUntil` is still in the future is the
  /// SAME cycle and must not compound twice.
  final Map<NodeId, ({Duration delay, DateTime activeUntil})>
      _rejectionBackoff = {};

  ConnectionMode get mode => _mode;

  /// Switches the policy mode.
  ///
  /// Switching to [ConnectionMode.auto] subscribes to the candidate
  /// stream and immediately considers every candidate currently in
  /// [DiscoveryService.currentCandidates] (so peers discovered while
  /// the policy was dormant are not missed).
  ///
  /// Switching to [ConnectionMode.manual] cancels the subscription.
  /// Existing connections are NOT torn down — the manager owns
  /// connection lifecycle; the policy only owns the decision of when
  /// to call `connectTo`.
  void setMode(ConnectionMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    if (_mode == ConnectionMode.auto) {
      // TODO(C5 followup): If setMode(auto) is called twice with an
      // intervening setMode(manual) before the catch-up microtasks drain,
      // concurrent catch-up batches may race past the dedup check. In
      // practice the ConnectionManager.connectTo reentrancy guard absorbs
      // the duplicates (now logged at debug above), so this is bounded —
      // but a mode-epoch counter would be cleaner.
      // DiscoveryService forwards scanner errors onto the candidate
      // stream; without onError each one becomes an uncaught zone error.
      _sub ??= _discovery.candidates.listen(
        _tryConnect,
        onError: (Object e, StackTrace st) {
          onLog?.call(LogLevel.warning, 'discovery stream error', e, st);
        },
      );
      // Catch up on candidates already discovered while we were
      // dormant.
      for (final c in _discovery.currentCandidates) {
        unawaited(_tryConnect(c));
      }
      // Already at target when auto-connect engages? Rest the radio now
      // rather than waiting for the next PeerOpened that will never come.
      final target = _targetConnections;
      if (target != null && _registry.connectionCount >= target) {
        onLog?.call(
          LogLevel.info,
          'connection target ($target) already met; resting discovery',
        );
        unawaited(_discovery.stop());
      }
    } else {
      final sub = _sub;
      _sub = null;
      unawaited(sub?.cancel());
    }
  }

  /// Connect attempts currently in flight. Counted toward the
  /// target-connections cap so a burst of scan candidates (which all
  /// pass the registry-count check before any connect lands) cannot
  /// overshoot it.
  int _inFlightAttempts = 0;

  Future<void> _tryConnect(ScanCandidate c) async {
    // Re-check on every event because we may be in the middle of
    // tearing down the subscription on a mode switch.
    if (_mode != ConnectionMode.auto) return;

    // Dedup: if we already know the NodeId for this address and that
    // NodeId is still in the registry, this is a duplicate
    // advertisement — silence it.
    final knownNode = _knownAddressToNode[c.address];
    if (knownNode != null && _registry.contains(knownNode)) return;

    // Backoff gate.
    final entry = _backoff[c.address];
    if (entry != null && _now().isBefore(entry.nextAttempt)) return;

    // Target-connections cap, including attempts still in flight.
    final cap = _targetConnections;
    if (cap != null && _registry.connectionCount + _inFlightAttempts >= cap) {
      return;
    }

    _inFlightAttempts++;
    try {
      final nodeId = await _connections.connectTo(c);
      _knownAddressToNode[c.address] = nodeId;
      _backoff.remove(c.address);
    } on AlreadyConnectingException catch (e) {
      // ConnectionManager.connectTo's reentrancy guard fired: another
      // attempt for this address is already in flight. Benign — no
      // backoff; the in-flight call will resolve normally. (This is a
      // TYPED exception on purpose: a generic StateError from the
      // connect path — e.g. a stale candidate after an adapter cycle —
      // is a real failure and falls through to the backoff branch.)
      onLog?.call(
        LogLevel.debug,
        'auto-connect skipped reentrant attempt for ${c.address}: $e',
      );
    } on NotABlueyPeerException {
      onLog?.call(
        LogLevel.debug,
        'candidate ${c.address} is not a bluey peer; long backoff',
      );
      _backoff[c.address] = (
        delay: _longBackoff,
        nextAttempt: _now().add(_longBackoff),
      );
    } on ConnectionRejectedException catch (e) {
      // The link came up but registration rejected it (cap/duplicate).
      // A real failure for backoff purposes: an immediate retry repeats
      // the whole connect→identify→reject→disconnect cycle on the next
      // advertisement.
      onLog?.call(
        LogLevel.debug,
        'auto-connect to ${c.address} rejected at registration: $e',
      );
      _recordRejectionBackoff(e.nodeId, address: c.address);
    } catch (e, st) {
      onLog?.call(
        LogLevel.warning,
        'auto-connect failed for ${c.address}',
        e,
        st,
      );
      _recordExponentialBackoff(c.address);
    } finally {
      _inFlightAttempts--;
    }
  }

  /// Records exponential backoff for a peer that rejected our connection
  /// (a local cap/duplicate rejection surfaced as
  /// [ConnectionRejectedException], or a peer-side GSP2 rejection surfaced
  /// as [ConnectionRejectedByPeerError]).
  ///
  /// Unlike [_recordExponentialBackoff], the window compounds from
  /// [_rejectionBackoff] — a NodeId-keyed memory that outlives the
  /// success-clear in [_tryConnect] — so consecutive reject cycles double
  /// (1s → 2s → 4s → … → [_maxBackoff]) instead of re-arming at
  /// [_initialBackoff] every cycle. The two signals a single rejection can
  /// raise are de-duplicated: while the previously-armed window is still
  /// active no new connect attempt (hence no new rejection) can have
  /// occurred, so we reuse the current delay rather than doubling again.
  void _recordRejectionBackoff(NodeId nodeId, {BleAddress? address}) {
    final now = _now();
    final memo = _rejectionBackoff[nodeId];
    final Duration next;
    if (memo != null && now.isBefore(memo.activeUntil)) {
      // Same rejection cycle (window still active) — the other signal for
      // this one rejection already compounded it; do not double again.
      next = memo.delay;
    } else {
      final prev = memo?.delay ?? Duration.zero;
      next = prev == Duration.zero
          ? _initialBackoff
          : Duration(
              milliseconds: (prev.inMilliseconds * 2).clamp(
                _initialBackoff.inMilliseconds,
                _maxBackoff.inMilliseconds,
              ),
            );
    }
    final nextAttempt = now.add(next);
    _rejectionBackoff[nodeId] = (delay: next, activeUntil: nextAttempt);
    // Arm every address that maps to this peer, plus the caller-supplied
    // one (the connectTo path throws before it records the mapping).
    final addresses = <BleAddress>{
      ?address,
      for (final e in _knownAddressToNode.entries)
        if (e.value == nodeId) e.key,
    };
    for (final a in addresses) {
      _backoff[a] = (delay: next, nextAttempt: nextAttempt);
    }
  }

  /// Doubles the address's previous backoff window, clamped to
  /// [_initialBackoff, _maxBackoff].
  void _recordExponentialBackoff(BleAddress address) {
    final prev = _backoff[address]?.delay ?? Duration.zero;
    final next = prev == Duration.zero
        ? _initialBackoff
        : Duration(
            milliseconds: (prev.inMilliseconds * 2).clamp(
              _initialBackoff.inMilliseconds,
              _maxBackoff.inMilliseconds,
            ),
          );
    _backoff[address] = (delay: next, nextAttempt: _now().add(next));
  }

  Future<void> dispose() async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    final errorsSub = _errorsSub;
    _errorsSub = null;
    await errorsSub?.cancel();
    final eventsSub = _eventsSub;
    _eventsSub = null;
    await eventsSub?.cancel();
  }
}
