import 'dart:async';

import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/rtt_estimate.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/services/rtt_tracker.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/protocol/failure_detector.dart';
import 'package:gossip/src/protocol/messages/ping.dart';
import 'package:gossip/src/protocol/messages/ack.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

void main() {
  group('FailureDetector adaptive timeouts', () {
    late NodeId localNode;
    late NodeId peerNode;
    late PeerRegistry peerRegistry;
    late InMemoryTimePort timePort;
    late InMemoryMessageBus bus;
    late InMemoryMessagePort localPort;
    late InMemoryMessagePort peerPort;
    late ProtocolCodec codec;

    setUp(() {
      localNode = NodeId('local');
      peerNode = NodeId('peer1');
      peerRegistry = PeerRegistry(localNode: localNode, initialIncarnation: 0);
      peerRegistry.addPeer(peerNode, occurredAt: DateTime.now());

      timePort = InMemoryTimePort();
      bus = InMemoryMessageBus();
      localPort = InMemoryMessagePort(localNode, bus);
      peerPort = InMemoryMessagePort(peerNode, bus);
      codec = ProtocolCodec();
    });

    test(
      'effectivePingTimeout uses RTT-based timeout when estimate provided',
      () {
        // Pre-seed RTT tracker with low-latency estimate (no sample needed)
        final rttTracker = RttTracker(
          initialEstimate: RttEstimate(
            smoothedRtt: const Duration(milliseconds: 100),
            rttVariance: const Duration(milliseconds: 25),
          ),
        );

        final detector = FailureDetector(
          localNode: localNode,
          peerRegistry: peerRegistry,
          timePort: timePort,
          messagePort: localPort,
          rttTracker: rttTracker,
        );

        // timeout = 100 + 4 * 25 = 200ms (minimum bound)
        expect(
          detector.effectivePingTimeout,
          equals(const Duration(milliseconds: 200)),
        );
      },
    );

    test(
      'effectivePingTimeout uses initial conservative value before samples',
      () {
        final rttTracker = RttTracker(); // No samples yet

        final detector = FailureDetector(
          localNode: localNode,
          peerRegistry: peerRegistry,
          timePort: timePort,
          messagePort: localPort,
          rttTracker: rttTracker,
        );

        // Before samples, should use initial estimate (1s + 4 * 500ms = 3s)
        // But clamped to max of 10s, so 3s is fine
        expect(
          detector.effectivePingTimeout.inMilliseconds,
          greaterThanOrEqualTo(2000),
        );
      },
    );

    test('effectivePingTimeout respects minimum bound of 200ms', () {
      // Very fast RTT
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(milliseconds: 20),
          rttVariance: const Duration(milliseconds: 5),
        ),
      );
      rttTracker.recordSample(const Duration(milliseconds: 20));

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: localPort,
        rttTracker: rttTracker,
      );

      // Raw timeout = 20 + 4 * 5 = 40ms, but min is 200ms
      expect(
        detector.effectivePingTimeout,
        equals(const Duration(milliseconds: 200)),
      );
    });

    test('effectivePingTimeout respects maximum bound of 10s', () {
      // Very slow RTT
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(seconds: 5),
          rttVariance: const Duration(seconds: 3),
        ),
      );
      rttTracker.recordSample(const Duration(seconds: 5));

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: localPort,
        rttTracker: rttTracker,
      );

      // Raw timeout = 5000 + 4 * 3000 = 17000ms, but max is 10000ms
      expect(
        detector.effectivePingTimeout,
        equals(const Duration(seconds: 10)),
      );
    });

    test('effectiveProbeInterval is 3x effectivePingTimeout', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(milliseconds: 200),
          rttVariance: const Duration(milliseconds: 50),
        ),
      );

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: localPort,
        rttTracker: rttTracker,
      );

      // pingTimeout = 200 + 4 * 50 = 400ms
      // probeInterval = 3 * 400 = 1200ms
      expect(
        detector.effectiveProbeInterval,
        equals(const Duration(milliseconds: 1200)),
      );
    });

    test('effectiveProbeInterval respects minimum bound of 500ms', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(milliseconds: 20),
          rttVariance: const Duration(milliseconds: 5),
        ),
      );
      rttTracker.recordSample(const Duration(milliseconds: 20));

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: localPort,
        rttTracker: rttTracker,
      );

      // pingTimeout = 200ms (minimum), probeInterval = 3 * 200 = 600ms
      // But min probeInterval is 500ms, so 600ms is fine
      expect(
        detector.effectiveProbeInterval.inMilliseconds,
        greaterThanOrEqualTo(500),
      );
    });

    test('effectiveProbeInterval respects maximum bound of 30s', () {
      final rttTracker = RttTracker(
        initialEstimate: RttEstimate(
          smoothedRtt: const Duration(seconds: 8),
          rttVariance: const Duration(seconds: 2),
        ),
      );
      rttTracker.recordSample(const Duration(seconds: 8));

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: localPort,
        rttTracker: rttTracker,
      );

      // pingTimeout = 10s (max), probeInterval = 3 * 10 = 30s (at max)
      expect(
        detector.effectiveProbeInterval,
        equals(const Duration(seconds: 30)),
      );
    });

    test('effectivePingTimeoutForPeer uses per-peer RTT when available', () {
      final rttTracker = RttTracker(); // Conservative global default

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: localPort,
        rttTracker: rttTracker,
      );

      // Seed per-peer RTT: 100ms SRTT → timeout = 100 + 4*50 = 300ms
      peerRegistry.recordPeerRtt(peerNode, const Duration(milliseconds: 100));

      final peerTimeout = detector.effectivePingTimeoutForPeer(peerNode);
      // Per-peer timeout should be much lower than the global conservative default
      expect(peerTimeout.inMilliseconds, lessThan(1000));
      // Should be at least the minimum bound
      expect(peerTimeout.inMilliseconds, greaterThanOrEqualTo(200));
    });

    test(
      'effectivePingTimeoutForPeer falls back to global when no per-peer estimate',
      () {
        final rttTracker = RttTracker(); // Conservative global default

        final detector = FailureDetector(
          localNode: localNode,
          peerRegistry: peerRegistry,
          timePort: timePort,
          messagePort: localPort,
          rttTracker: rttTracker,
        );

        // No per-peer RTT recorded
        final peerTimeout = detector.effectivePingTimeoutForPeer(peerNode);
        // Should equal the global effectivePingTimeout
        expect(peerTimeout, equals(detector.effectivePingTimeout));
      },
    );

    test(
      'effectivePingTimeoutForPeer falls back to global for unknown peer',
      () {
        final rttTracker = RttTracker();

        final detector = FailureDetector(
          localNode: localNode,
          peerRegistry: peerRegistry,
          timePort: timePort,
          messagePort: localPort,
          rttTracker: rttTracker,
        );

        final unknownNode = NodeId('unknown');
        final timeout = detector.effectivePingTimeoutForPeer(unknownNode);
        expect(timeout, equals(detector.effectivePingTimeout));
      },
    );

    test('probe round uses per-peer timeout for known peer with RTT', () async {
      final rttTracker = RttTracker();

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: localPort,
        rttTracker: rttTracker,
      );

      // Seed per-peer RTT: 100ms → timeout ~300ms (clamped to min 200ms)
      peerRegistry.recordPeerRtt(peerNode, const Duration(milliseconds: 100));

      detector.startListening();

      // Set up peer to respond to pings
      Ping? receivedPing;
      final pingCompleter = Completer<void>();
      final subscription = peerPort.incoming.listen((msg) {
        final decoded = codec.decode(msg.bytes);
        if (decoded is Ping && !pingCompleter.isCompleted) {
          receivedPing = decoded;
          pingCompleter.complete();
        }
      });

      final probeRoundFuture = detector.performProbeRound();
      await Future.delayed(Duration.zero);
      await pingCompleter.future;

      // Respond with Ack before per-peer timeout (within 200ms)
      await timePort.advance(const Duration(milliseconds: 50));
      final ack = Ack(sender: peerNode, sequence: receivedPing!.sequence);
      await peerPort.send(localNode, codec.encode(ack));
      await Future.delayed(Duration.zero);

      await probeRoundFuture;

      // Probe should succeed (no failure recorded)
      final peer = peerRegistry.getPeer(peerNode)!;
      expect(peer.failedProbeCount, equals(0));

      await subscription.cancel();
      detector.stopListening();
    });

    test('timeout adapts as RTT samples are collected', () async {
      final rttTracker = RttTracker();

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: localPort,
        rttTracker: rttTracker,
      );

      detector.startListening();

      // Initial timeout (conservative, no samples)
      final initialTimeout = detector.effectivePingTimeout;
      expect(initialTimeout.inMilliseconds, greaterThanOrEqualTo(2000));

      // Simulate several fast RTT samples
      for (var i = 0; i < 10; i++) {
        Ping? receivedPing;
        final pingCompleter = Completer<void>();
        final subscription = peerPort.incoming.listen((msg) {
          final decoded = codec.decode(msg.bytes);
          if (decoded is Ping && !pingCompleter.isCompleted) {
            receivedPing = decoded;
            pingCompleter.complete();
          }
        });

        final probeRoundFuture = detector.performProbeRound();
        await Future.delayed(Duration.zero);
        await pingCompleter.future;

        // Simulate 100ms RTT
        await timePort.advance(const Duration(milliseconds: 100));

        final ack = Ack(sender: peerNode, sequence: receivedPing!.sequence);
        await peerPort.send(localNode, codec.encode(ack));
        await Future.delayed(Duration.zero);

        await probeRoundFuture;
        await subscription.cancel();
      }

      // After samples, timeout should be much lower
      final adaptedTimeout = detector.effectivePingTimeout;
      expect(
        adaptedTimeout.inMilliseconds,
        lessThan(initialTimeout.inMilliseconds),
      );
      // Should be around 100ms + 4 * variance, clamped to min 200ms
      expect(adaptedTimeout.inMilliseconds, lessThanOrEqualTo(500));

      detector.stopListening();
    });
  });
}
