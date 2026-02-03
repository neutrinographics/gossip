import 'dart:async';

import 'package:gossip/src/domain/value_objects/node_id.dart';
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
  group('FailureDetector RTT tracking', () {
    late NodeId localNode;
    late NodeId peerNode;
    late PeerRegistry peerRegistry;
    late InMemoryTimePort timePort;
    late InMemoryMessageBus bus;
    late InMemoryMessagePort localPort;
    late InMemoryMessagePort peerPort;
    late RttTracker rttTracker;
    late FailureDetector detector;
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
      rttTracker = RttTracker();
      codec = ProtocolCodec();

      detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: localPort,
        rttTracker: rttTracker,
        pingTimeout: const Duration(milliseconds: 500),
        indirectPingTimeout: const Duration(milliseconds: 500),
      );
    });

    test('records RTT sample when Ack is received', () async {
      detector.startListening();

      // Set up listener to capture pings before starting probe round
      Ping? receivedPing;
      final pingCompleter = Completer<void>();
      final subscription = peerPort.incoming.listen((msg) {
        final decoded = codec.decode(msg.bytes);
        if (decoded is Ping) {
          receivedPing = decoded;
          pingCompleter.complete();
        }
      });

      // Start a probe round (don't await - it blocks waiting for ack)
      final probeRoundFuture = detector.performProbeRound();

      // Wait for ping to arrive
      await Future.delayed(Duration.zero);
      await pingCompleter.future;
      expect(receivedPing, isNotNull);

      // Advance time to simulate RTT of 150ms
      await timePort.advance(const Duration(milliseconds: 150));

      // Send Ack back
      final ack = Ack(sender: peerNode, sequence: receivedPing!.sequence);
      await peerPort.send(localNode, codec.encode(ack));

      // Allow ack to be processed
      await Future.delayed(Duration.zero);

      // Probe round should complete now since Ack was received
      await probeRoundFuture;

      // Verify RTT was recorded
      expect(rttTracker.hasReceivedSamples, isTrue);
      expect(rttTracker.sampleCount, equals(1));
      // RTT should be 150ms
      expect(rttTracker.smoothedRtt.inMilliseconds, equals(150));

      await subscription.cancel();
      detector.stopListening();
    });

    test('exposes rttTracker for monitoring', () {
      expect(detector.rttTracker, same(rttTracker));
    });

    test('creates default RttTracker if none provided', () {
      final detectorWithoutTracker = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: localPort,
      );

      expect(detectorWithoutTracker.rttTracker, isNotNull);
      expect(detectorWithoutTracker.rttTracker.hasReceivedSamples, isFalse);
    });

    test('multiple probe rounds update RTT estimate', () async {
      detector.startListening();

      // Run 5 probe rounds with varying RTTs
      final rtts = [100, 120, 110, 130, 115];
      for (final rttMs in rtts) {
        // Set up listener for this round's ping
        Ping? receivedPing;
        final pingCompleter = Completer<void>();
        final subscription = peerPort.incoming.listen((msg) {
          final decoded = codec.decode(msg.bytes);
          if (decoded is Ping && !pingCompleter.isCompleted) {
            receivedPing = decoded;
            pingCompleter.complete();
          }
        });

        // Start probe round
        final probeRoundFuture = detector.performProbeRound();

        // Wait for ping
        await Future.delayed(Duration.zero);
        await pingCompleter.future;

        // Advance time to simulate RTT
        await timePort.advance(Duration(milliseconds: rttMs));

        // Send Ack back
        final ack = Ack(sender: peerNode, sequence: receivedPing!.sequence);
        await peerPort.send(localNode, codec.encode(ack));

        // Allow ack to be processed
        await Future.delayed(Duration.zero);

        // Complete the probe round
        await probeRoundFuture;

        await subscription.cancel();
      }

      // Verify multiple samples were recorded
      expect(rttTracker.sampleCount, equals(5));
      // Smoothed RTT should be close to average (around 115ms)
      expect(rttTracker.smoothedRtt.inMilliseconds, closeTo(115, 30));

      detector.stopListening();
    });

    test('does not record RTT when Ack times out', () async {
      detector.startListening();

      // Start a probe round
      final probeRoundFuture = detector.performProbeRound();

      // Allow ping to be sent
      await Future.delayed(Duration.zero);

      // Don't send Ack - let it timeout
      await timePort.advance(const Duration(milliseconds: 501));
      await timePort.advance(const Duration(milliseconds: 501));

      await probeRoundFuture;

      // Verify no RTT was recorded
      expect(rttTracker.hasReceivedSamples, isFalse);
      expect(rttTracker.sampleCount, equals(0));

      detector.stopListening();
    });
  });
}
