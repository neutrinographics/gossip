import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/errors/already_connecting_exception.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';
import 'package:gossip_bluey/src/application/services/auto_connect_policy.dart';
import 'package:gossip_bluey/src/application/services/connection_manager.dart';
import 'package:gossip_bluey/src/application/services/discovery_service.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';
import 'package:gossip_bluey/src/domain/value_objects/connection_mode.dart';
import 'package:gossip_bluey/src/domain/value_objects/scan_candidate.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';

import '../../fakes/fake_bluey_port.dart';

final _t0 = DateTime.utc(2026, 1, 1);

/// Mutable clock seam used by both the policy and the
/// `ConnectionManager` (so timestamps it stamps onto handles don't
/// rely on real wall-clock time). The policy reads via
/// `DateTime Function() now` injection; the manager reads via the
/// `Clock` class.
class _MutableClock implements Clock {
  DateTime instant;
  _MutableClock(this.instant);

  @override
  DateTime now() => instant;

  void advance(Duration d) {
    instant = instant.add(d);
  }
}

ScanCandidate _candidate(String addr, {DateTime? at}) => ScanCandidate(
      address: BleAddress(addr),
      lastSeen: at ?? _t0,
      rssi: -50,
    );

/// Yield to the microtask queue to let stream events propagate.
Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeBlueyPort port;
  late DiscoveryService discovery;
  late ConnectionManager connections;
  late ConnectionRegistry registry;
  late ServiceUuid serviceUuid;
  late _MutableClock clock;
  late int connectAndIdentifyCallCount;

  final localId = NodeId('11111111-1111-1111-1111-111111111111');
  final remoteAId = NodeId('22222222-2222-2222-2222-222222222222');
  final remoteBId = NodeId('33333333-3333-3333-3333-333333333333');
  final addrA = BleAddress(remoteAId.value);
  final addrB = BleAddress(remoteBId.value);

  setUp(() async {
    final network = FakeBlueyNetwork();
    port = FakeBlueyPort(localNodeId: localId, network: network);
    // Remotes register with the fake network so `connectAndIdentify`
    // (which calls `connect(NodeId)`) can resolve them. They do NOT
    // advertise, because that would cause the live scan stream to
    // continuously emit them — these tests drive scan events
    // deterministically via `port.emitCandidate(...)`.
    FakeBlueyPort(localNodeId: remoteAId, network: network);
    FakeBlueyPort(localNodeId: remoteBId, network: network);
    serviceUuid = ServiceUuid('f0000000-0000-0000-0000-67c155b1ea7c');

    clock = _MutableClock(_t0);
    registry = ConnectionRegistry();
    discovery = DiscoveryService(port: port, serviceUuid: serviceUuid);
    connections = ConnectionManager(
      port: port,
      registry: registry,
      metrics: BlueyMetrics(),
      clock: clock,
    );
    connectAndIdentifyCallCount = 0;
    port.onConnectAndIdentify = (_) => connectAndIdentifyCallCount++;
    await discovery.start();
  });

  tearDown(() async {
    await connections.dispose();
    await discovery.dispose();
    await port.dispose();
  });

  group('AutoConnectPolicy', () {
    test('defaults to ConnectionMode.manual', () {
      final policy = AutoConnectPolicy(
        discovery: discovery,
        connections: connections,
        registry: registry,
        now: () => clock.instant,
      );
      expect(policy.mode, ConnectionMode.manual);
    });

    test(
      'manual mode: candidate emission does NOT trigger connectTo',
      () async {
        AutoConnectPolicy(
          discovery: discovery,
          connections: connections,
          registry: registry,
          now: () => clock.instant,
        );

        port.emitCandidate(_candidate(addrA.value));
        await _pump();
        clock.advance(const Duration(seconds: 10));
        await _pump();

        expect(connectAndIdentifyCallCount, 0);
      },
    );

    test('auto mode: each new candidate triggers connectTo once', () async {
      final policy = AutoConnectPolicy(
        discovery: discovery,
        connections: connections,
        registry: registry,
        now: () => clock.instant,
      );
      policy.setMode(ConnectionMode.auto);

      port.emitCandidate(_candidate(addrA.value));
      await _pump();
      await _pump();

      expect(connectAndIdentifyCallCount, 1);
    });

    test(
      'auto mode: backoff prevents immediate re-attempt after failure',
      () async {
        port.connectAndIdentifyFailureInjector = (_) => true;
        final policy = AutoConnectPolicy(
          discovery: discovery,
          connections: connections,
          registry: registry,
          now: () => clock.instant,
          initialBackoff: const Duration(seconds: 1),
        );
        policy.setMode(ConnectionMode.auto);

        port.emitCandidate(_candidate(addrA.value));
        await _pump();
        await _pump();
        expect(connectAndIdentifyCallCount, 1);

        // Second emission before the 1s backoff window expires.
        clock.advance(const Duration(milliseconds: 500));
        port.emitCandidate(_candidate(addrA.value));
        await _pump();
        await _pump();
        expect(connectAndIdentifyCallCount, 1);
      },
    );

    test('auto mode: backoff is exponential and capped', () async {
      port.connectAndIdentifyFailureInjector = (_) => true;
      final policy = AutoConnectPolicy(
        discovery: discovery,
        connections: connections,
        registry: registry,
        now: () => clock.instant,
        initialBackoff: const Duration(seconds: 1),
        maxBackoff: const Duration(seconds: 8),
      );
      policy.setMode(ConnectionMode.auto);

      // Helper: drive an attempt by waiting past the current backoff
      // and emitting another candidate.
      Future<void> attempt(Duration wait) async {
        clock.advance(wait);
        port.emitCandidate(_candidate(addrA.value));
        await _pump();
        await _pump();
      }

      // Attempt 1 — immediate (no backoff yet). Sets backoff to 1s.
      await attempt(Duration.zero);
      expect(connectAndIdentifyCallCount, 1);

      // Attempt 2 — wait 1s. Sets backoff to 2s.
      await attempt(const Duration(seconds: 1));
      expect(connectAndIdentifyCallCount, 2);

      // Attempt 3 — wait 2s. Sets backoff to 4s.
      await attempt(const Duration(seconds: 2));
      expect(connectAndIdentifyCallCount, 3);

      // Attempt 4 — wait 4s. Sets backoff to 8s (cap).
      await attempt(const Duration(seconds: 4));
      expect(connectAndIdentifyCallCount, 4);

      // Attempt 5 — wait 8s. Backoff already at cap, stays 8s.
      await attempt(const Duration(seconds: 8));
      expect(connectAndIdentifyCallCount, 5);

      // Attempt 6 — only 4s elapsed: cap is 8s, must NOT attempt.
      clock.advance(const Duration(seconds: 4));
      port.emitCandidate(_candidate(addrA.value));
      await _pump();
      await _pump();
      expect(connectAndIdentifyCallCount, 5);
    });

    test(
      'auto mode: target-connections cap prevents further attempts',
      () async {
        final policy = AutoConnectPolicy(
          discovery: discovery,
          connections: connections,
          registry: registry,
          now: () => clock.instant,
          targetConnections: 1,
        );
        policy.setMode(ConnectionMode.auto);

        port.emitCandidate(_candidate(addrA.value));
        await _pump();
        await _pump();
        // ConnectionManager's port event listener registers the handle.
        await _pump();
        expect(registry.connectionCount, 1);
        expect(connectAndIdentifyCallCount, 1);

        port.emitCandidate(_candidate(addrB.value));
        await _pump();
        await _pump();
        expect(connectAndIdentifyCallCount, 1);
      },
    );

    test(
      'auto mode: NotABlueyPeerException triggers long backoff',
      () async {
        port.notABlueyPeerInjector = (a) => a == addrA;
        final policy = AutoConnectPolicy(
          discovery: discovery,
          connections: connections,
          registry: registry,
          now: () => clock.instant,
          initialBackoff: const Duration(seconds: 1),
          maxBackoff: const Duration(seconds: 8),
          longBackoff: const Duration(minutes: 10),
        );
        policy.setMode(ConnectionMode.auto);

        port.emitCandidate(_candidate(addrA.value));
        await _pump();
        await _pump();
        expect(connectAndIdentifyCallCount, 1);

        // Advance well past the normal max backoff but well before the
        // long backoff window expires.
        clock.advance(const Duration(seconds: 30));
        port.emitCandidate(_candidate(addrA.value));
        await _pump();
        await _pump();
        expect(connectAndIdentifyCallCount, 1);
      },
    );

    test(
      'auto mode: known-but-disconnected address eligible after backoff '
      'expires',
      () async {
        var failNext = true;
        port.connectAndIdentifyFailureInjector = (_) {
          if (failNext) {
            failNext = false;
            return true;
          }
          return false;
        };
        final policy = AutoConnectPolicy(
          discovery: discovery,
          connections: connections,
          registry: registry,
          now: () => clock.instant,
          initialBackoff: const Duration(seconds: 1),
        );
        policy.setMode(ConnectionMode.auto);

        port.emitCandidate(_candidate(addrA.value));
        await _pump();
        await _pump();
        expect(connectAndIdentifyCallCount, 1);

        clock.advance(const Duration(seconds: 2));
        port.emitCandidate(_candidate(addrA.value));
        await _pump();
        await _pump();
        expect(connectAndIdentifyCallCount, 2);
      },
    );

    test('setMode(manual) preserves existing connections', () async {
      final policy = AutoConnectPolicy(
        discovery: discovery,
        connections: connections,
        registry: registry,
        now: () => clock.instant,
      );
      policy.setMode(ConnectionMode.auto);

      port.emitCandidate(_candidate(addrA.value));
      await _pump();
      await _pump();
      await _pump();
      expect(registry.connectionCount, 1);
      expect(connectAndIdentifyCallCount, 1);

      policy.setMode(ConnectionMode.manual);
      expect(registry.connectionCount, 1);

      port.emitCandidate(_candidate(addrB.value));
      await _pump();
      await _pump();
      expect(connectAndIdentifyCallCount, 1);
    });

    test(
      'auto mode: AlreadyConnectingException from connectTo is swallowed '
      'without backoff',
      () async {
        final policy = AutoConnectPolicy(
          discovery: discovery,
          connections: connections,
          registry: registry,
          now: () => clock.instant,
          initialBackoff: const Duration(seconds: 1),
        );
        policy.setMode(ConnectionMode.auto);

        // Simulate ConnectionManager.connectTo's reentrancy guard firing
        // via its TYPED exception. The policy should swallow it without
        // recording backoff. (A generic StateError — e.g. a stale
        // candidate after an adapter cycle — must record backoff; see
        // resilience_test.dart.)
        port.injectConnectAndIdentifyError(
          const BleAddress('AA:BB:CC:DD:EE:01'),
          AlreadyConnectingException(const BleAddress('AA:BB:CC:DD:EE:01')),
        );
        port.emitCandidate(_candidate('AA:BB:CC:DD:EE:01'));
        await _pump();
        await _pump();
        expect(port.connectAndIdentifyCallCount, 1);

        // No backoff was recorded — a fresh emission for the same
        // address should immediately retry (instead of being deferred
        // by an exponential-backoff window).
        final beforeRetry = port.connectAndIdentifyCallCount;
        port.emitCandidate(_candidate('AA:BB:CC:DD:EE:01'));
        await _pump();
        await _pump();
        expect(port.connectAndIdentifyCallCount, beforeRetry + 1);
      },
    );

    test(
      'auto mode: a registration-rejected connect records backoff — '
      'no hot retry on the next advertisement (COR3-6)',
      () async {
        // Self-contained fixtures: the shared setUp manager has no cap
        // and would register the peer before the capped manager sees it.
        final isolatedNetwork = FakeBlueyNetwork();
        final isolatedPort = FakeBlueyPort(
          localNodeId: localId,
          network: isolatedNetwork,
        );
        FakeBlueyPort(localNodeId: remoteAId, network: isolatedNetwork);
        FakeBlueyPort(localNodeId: remoteBId, network: isolatedNetwork);
        final isolatedRegistry = ConnectionRegistry();
        final isolatedDiscovery = DiscoveryService(
          port: isolatedPort,
          serviceUuid: serviceUuid,
        );
        // Capped at 1 connection: the second connect succeeds at the
        // GATT level but is cap-rejected at registration.
        final cappedConnections = ConnectionManager(
          port: isolatedPort,
          registry: isolatedRegistry,
          metrics: BlueyMetrics(),
          maxConnections: 1,
          clock: clock,
        );
        addTearDown(() async {
          await cappedConnections.dispose();
          await isolatedDiscovery.dispose();
          await isolatedPort.dispose();
        });
        var attempts = 0;
        isolatedPort.onConnectAndIdentify = (_) => attempts++;
        await isolatedDiscovery.start();
        final policy = AutoConnectPolicy(
          discovery: isolatedDiscovery,
          connections: cappedConnections,
          registry: isolatedRegistry,
          now: () => clock.instant,
          initialBackoff: const Duration(seconds: 1),
        );
        policy.setMode(ConnectionMode.auto);

        // Fill the single slot.
        isolatedPort.emitCandidate(_candidate(addrA.value));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(isolatedRegistry.connectionCount, 1);
        expect(attempts, 1);

        // B connects + identifies, then gets cap-rejected.
        isolatedPort.emitCandidate(_candidate(addrB.value));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(attempts, 2);
        expect(isolatedRegistry.contains(remoteBId), isFalse);

        // Re-advertisement before the backoff window expires must NOT
        // trigger another connect→identify→reject→disconnect cycle.
        clock.advance(const Duration(milliseconds: 500));
        isolatedPort.emitCandidate(_candidate(addrB.value));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          attempts,
          2,
          reason:
              'success-on-rejection clears backoff and repeats the full '
              'GATT connect churn on every advertisement',
        );
      },
    );

    test(
      'setMode(auto) catches up on currently-emitted candidates',
      () async {
        // Manual: candidate is recorded in discovery.currentCandidates
        // but the policy does not act on it.
        final policy = AutoConnectPolicy(
          discovery: discovery,
          connections: connections,
          registry: registry,
          now: () => clock.instant,
        );

        port.emitCandidate(_candidate(addrA.value));
        await _pump();
        expect(discovery.currentCandidates, hasLength(1));
        expect(connectAndIdentifyCallCount, 0);

        policy.setMode(ConnectionMode.auto);
        await _pump();
        await _pump();
        expect(connectAndIdentifyCallCount, 1);
      },
    );
  });
}
