import 'dart:async';

import 'package:gossip/gossip.dart';

import '../../domain/aggregates/connection_registry.dart';
import '../../domain/errors/not_a_bluey_peer_exception.dart';
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
        _longBackoff = longBackoff;

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

  /// Per-address backoff bookkeeping. `delay` is the current backoff
  /// window length (used to compute the next exponential step);
  /// `nextAttempt` is the wall-clock instant before which the policy
  /// must NOT call [ConnectionManager.connectTo] for this address.
  final Map<BleAddress, ({Duration delay, DateTime nextAttempt})> _backoff = {};

  /// Address → resolved NodeId cache. Once we've successfully
  /// identified a peer at an address, repeated scan emissions for that
  /// address are silenced as long as the NodeId is still in the
  /// connection registry.
  final Map<BleAddress, NodeId> _knownAddressToNode = {};

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
      _sub ??= _discovery.candidates.listen(_tryConnect);
      // Catch up on candidates already discovered while we were
      // dormant.
      for (final c in _discovery.currentCandidates) {
        unawaited(_tryConnect(c));
      }
    } else {
      final sub = _sub;
      _sub = null;
      unawaited(sub?.cancel());
    }
  }

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

    // Target-connections cap.
    final cap = _targetConnections;
    if (cap != null && _registry.connectionCount >= cap) {
      return;
    }

    try {
      final nodeId = await _connections.connectTo(c);
      _knownAddressToNode[c.address] = nodeId;
      _backoff.remove(c.address);
    } on NotABlueyPeerException {
      onLog?.call(
        LogLevel.debug,
        'candidate ${c.address} is not a bluey peer; long backoff',
      );
      _backoff[c.address] = (
        delay: _longBackoff,
        nextAttempt: _now().add(_longBackoff),
      );
    } catch (e, st) {
      onLog?.call(
        LogLevel.warning,
        'auto-connect failed for ${c.address}',
        e,
        st,
      );
      final prev = _backoff[c.address]?.delay ?? Duration.zero;
      final next = prev == Duration.zero
          ? _initialBackoff
          : Duration(
              milliseconds: (prev.inMilliseconds * 2).clamp(
                _initialBackoff.inMilliseconds,
                _maxBackoff.inMilliseconds,
              ),
            );
      _backoff[c.address] = (delay: next, nextAttempt: _now().add(next));
    }
  }

  Future<void> dispose() async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
  }
}
