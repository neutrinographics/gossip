import 'dart:math';

import 'package:gossip/src/domain/events/domain_event.dart'
    show PeerStatus, PeerStatusChanged;
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/infrastructure/ports/message_port.dart';
import 'package:gossip/src/protocol/messages/ack.dart';
import 'package:gossip/src/protocol/messages/ping.dart';
import 'package:gossip/src/protocol/messages/ping_req.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Construction & peer selection
  // ---------------------------------------------------------------------------

  group('Construction & peer selection', () {
    test('can be constructed with required dependencies', () {
      final h = FailureDetectorTestHarness();
      expect(h.detector, isNotNull);
    });

    test('selectRandomPeer returns null when no reachable peers', () {
      final h = FailureDetectorTestHarness();
      expect(h.detector.selectRandomPeer(), isNull);
    });

    test('selectRandomPeer returns a reachable peer', () {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      final selected = h.detector.selectRandomPeer();
      expect(selected, isNotNull);
      expect(selected!.id, equals(peer.id));
    });
  });

  // ---------------------------------------------------------------------------
  // Probing hold
  // ---------------------------------------------------------------------------

  group('Probing hold', () {
    test('setProbingHold prevents peer from being selected', () {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      // Set hold far in the future
      final holdUntil = h.timePort.nowMs + 10000;
      h.detector.setProbingHold(peer.id, holdUntil);

      expect(h.detector.selectRandomPeer(), isNull);
    });

    test('peer becomes selectable after hold expires', () async {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      // Set hold 100ms in the future
      final holdUntil = h.timePort.nowMs + 100;
      h.detector.setProbingHold(peer.id, holdUntil);

      expect(h.detector.selectRandomPeer(), isNull);

      // Advance past hold expiry
      await h.timePort.advance(const Duration(milliseconds: 101));

      final selected = h.detector.selectRandomPeer();
      expect(selected, isNotNull);
      expect(selected!.id, equals(peer.id));
    });

    test('clearProbingHold makes peer immediately selectable', () {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      // Set hold far in the future
      final holdUntil = h.timePort.nowMs + 10000;
      h.detector.setProbingHold(peer.id, holdUntil);

      expect(h.detector.selectRandomPeer(), isNull);

      h.detector.clearProbingHold(peer.id);

      final selected = h.detector.selectRandomPeer();
      expect(selected, isNotNull);
      expect(selected!.id, equals(peer.id));
    });

    test('hasProbingHold returns true when hold is active', () {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      expect(h.detector.hasProbingHold(peer.id), isFalse);

      final holdUntil = h.timePort.nowMs + 10000;
      h.detector.setProbingHold(peer.id, holdUntil);

      expect(h.detector.hasProbingHold(peer.id), isTrue);
    });

    test('hasProbingHold returns false after hold expires', () async {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      final holdUntil = h.timePort.nowMs + 100;
      h.detector.setProbingHold(peer.id, holdUntil);

      expect(h.detector.hasProbingHold(peer.id), isTrue);

      await h.timePort.advance(const Duration(milliseconds: 101));

      expect(h.detector.hasProbingHold(peer.id), isFalse);
    });

    test('only held peers are excluded from selection', () {
      final h = FailureDetectorTestHarness();
      final peer1 = h.addPeer('peer1');
      final peer2 = h.addPeer('peer2');

      // Hold peer1, leave peer2 available
      final holdUntil = h.timePort.nowMs + 10000;
      h.detector.setProbingHold(peer1.id, holdUntil);

      // Should always select peer2
      for (var i = 0; i < 10; i++) {
        final selected = h.detector.selectRandomPeer();
        expect(selected, isNotNull);
        expect(selected!.id, equals(peer2.id));
      }
    });

    test('clearProbingHold on non-held peer is no-op', () {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      // Should not throw
      h.detector.clearProbingHold(peer.id);

      final selected = h.detector.selectRandomPeer();
      expect(selected, isNotNull);
      expect(selected!.id, equals(peer.id));
    });
  });

  // ---------------------------------------------------------------------------
  // Message handling
  // ---------------------------------------------------------------------------

  group('Message handling', () {
    test('handlePing returns an Ack with matching sequence', () {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      final ping = Ping(sender: peer.id, sequence: 42);
      final ack = h.detector.handlePing(ping);

      expect(ack.sender, equals(h.localNode));
      expect(ack.sequence, equals(42));
    });

    test('listens to incoming Ping and responds with Ack', () async {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      h.startListening();

      final ackFuture = peer.port.incoming.first;
      await h.sendPing(peer, sequence: 42);

      final message = await ackFuture.timeout(const Duration(seconds: 1));
      final ack = h.codec.decode(message.bytes);

      expect(ack, isA<Ack>());
      expect((ack as Ack).sender, equals(h.localNode));
      expect(ack.sequence, equals(42));

      h.stopListening();
    });

    test('sends SWIM messages with high priority', () async {
      final bus = InMemoryMessageBus();
      final localPort = InMemoryMessagePort(NodeId('local'), bus);
      final capPort = PriorityCapturingMessagePort(localPort);
      final peerPort = InMemoryMessagePort(NodeId('peer1'), bus);

      final hCap = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
        messagePort: capPort,
      );
      hCap.addPeer('peer1');
      hCap.startListening();

      final probeRoundFuture = hCap.detector.performProbeRound();
      await hCap.flush();

      expect(capPort.capturedPriorities, isNotEmpty);
      expect(
        capPort.capturedPriorities.first,
        equals(MessagePriority.high),
        reason: 'Ping should be sent with high priority',
      );

      // Send a Ping to detector so it responds with Ack
      final codec = ProtocolCodec();
      final pingMsg = Ping(sender: NodeId('peer1'), sequence: 99);
      await peerPort.send(NodeId('local'), codec.encode(pingMsg));
      await hCap.flush();

      expect(capPort.capturedPriorities.length, greaterThanOrEqualTo(2));
      expect(
        capPort.capturedPriorities,
        everyElement(equals(MessagePriority.high)),
        reason: 'All SWIM messages should use high priority',
      );

      await hCap.advancePastTimeout();
      await probeRoundFuture;
      hCap.stopListening();
    });
  });

  // ---------------------------------------------------------------------------
  // Probe round
  // ---------------------------------------------------------------------------

  group('Probe round', () {
    test('sends Ping to random peer', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
      );
      final peer = h.addPeer('peer1');

      final pingFuture = h.expectPing(peer);
      final probeRoundFuture = h.detector.performProbeRound();
      final ping = await pingFuture;

      expect(ping.sender, equals(h.localNode));
      expect(ping.sequence, greaterThan(0));

      await h.advancePastTimeout();
      await probeRoundFuture;
    });

    test('records failure when no Ack arrives', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
      );
      h.addPeer('peer1');

      await h.probeWithTimeout();

      final peer = h.peerRegistry.getPeer(NodeId('peer1'))!;
      expect(
        peer.failedProbeCount,
        equals(1),
        reason: 'Probe failure should be recorded when no Ack arrives',
      );
    });

    test(
      'late Ack arriving during indirect ping phase prevents failure',
      () async {
        final h = FailureDetectorTestHarness(
          pingTimeout: const Duration(milliseconds: 500),
          random: Random(42),
        );
        final peer = h.addPeer('peer1');
        final intermediary = h.addPeer('intermediary');

        h.startListening();

        Ping? receivedPing;
        NodeId? pingTarget;
        final peerSub = peer.port.incoming.listen((msg) {
          final decoded = h.codec.decode(msg.bytes);
          if (decoded is Ping) {
            receivedPing = decoded;
            pingTarget = peer.id;
          }
        });
        final intermediarySub = intermediary.port.incoming.listen((msg) {
          final decoded = h.codec.decode(msg.bytes);
          if (decoded is Ping) {
            receivedPing = decoded;
            pingTarget = intermediary.id;
          }
        });

        final probeRoundFuture = h.detector.performProbeRound();
        await h.flush();

        expect(receivedPing, isNotNull, reason: 'Ping should have been sent');

        // Advance past direct timeout → indirect ping phase
        await h.timePort.advance(const Duration(milliseconds: 501));
        await h.flush();

        // Send "late" Ack during indirect phase
        final ack = Ack(sender: pingTarget!, sequence: receivedPing!.sequence);
        final senderPort = pingTarget == peer.id
            ? peer.port
            : intermediary.port;
        await senderPort.send(h.localNode, h.codec.encode(ack));
        await h.flush();

        await h.timePort.advance(const Duration(milliseconds: 500));
        await probeRoundFuture;

        final probed = h.peerRegistry.getPeer(pingTarget!);
        expect(
          probed!.failedProbeCount,
          equals(0),
          reason: 'Late Ack should prevent probe failure',
        );
        expect(probed.status, equals(PeerStatus.reachable));

        await peerSub.cancel();
        await intermediarySub.cancel();
        h.stopListening();
      },
    );

    test(
      'late Ack in 2-device scenario (no intermediaries) prevents failure',
      () async {
        final h = FailureDetectorTestHarness(
          pingTimeout: const Duration(milliseconds: 500),
        );
        final peer = h.addPeer('peer1');

        h.startListening();

        final pingFuture = h.expectPing(peer);
        final probeRoundFuture = h.detector.performProbeRound();
        final ping = await pingFuture;

        // Advance past direct timeout → grace period
        await h.timePort.advance(const Duration(milliseconds: 501));
        await h.flush();

        // Send "late" Ack during grace period
        await h.sendAck(peer, ping.sequence);

        await h.timePort.advance(const Duration(milliseconds: 500));
        await probeRoundFuture;

        final probed = h.peerRegistry.getPeer(peer.id)!;
        expect(
          probed.failedProbeCount,
          equals(0),
          reason: 'Late Ack during grace period should prevent failure',
        );
        expect(probed.status, equals(PeerStatus.reachable));

        h.stopListening();
      },
    );

    test('indirect ping success prevents probe failure', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
      );
      final target = h.addPeer('target');
      final intermediary = h.addPeer('intermediary');

      h.startListening();

      // Listen on both peers to detect which gets the direct Ping
      Ping? targetPing;
      final targetSub = target.port.incoming.listen((msg) {
        final decoded = h.codec.decode(msg.bytes);
        if (decoded is Ping) targetPing = decoded;
      });
      final intermediarySub = intermediary.port.incoming.listen((msg) {
        final decoded = h.codec.decode(msg.bytes);
        if (decoded is PingReq) {
          // Intermediary responds to PingReq with Ack (simulating successful
          // indirect probe: intermediary pinged target, got Ack, forwards it)
          final ack = Ack(sender: intermediary.id, sequence: decoded.sequence);
          intermediary.port.send(h.localNode, h.codec.encode(ack));
        }
      });

      final probeRoundFuture = h.detector.performProbeRound();
      await h.flush();

      // Determine which peer was the probe target
      final TestPeer probeTarget;
      if (targetPing != null) {
        probeTarget = target;
      } else {
        probeTarget = intermediary;
        // Wire up target (acting as intermediary) to respond to PingReqs
        await targetSub.cancel();
        target.port.incoming.listen((msg) {
          final decoded = h.codec.decode(msg.bytes);
          if (decoded is PingReq) {
            final ack = Ack(sender: target.id, sequence: decoded.sequence);
            target.port.send(h.localNode, h.codec.encode(ack));
          }
        });
      }

      // Let direct ping timeout expire → triggers indirect ping phase
      await h.timePort.advance(const Duration(milliseconds: 501));
      await h.flush(3);

      // Advance past indirect timeout so probe completes
      await h.timePort.advance(const Duration(milliseconds: 501));
      await probeRoundFuture;

      final probed = h.peerRegistry.getPeer(probeTarget.id)!;
      expect(
        probed.failedProbeCount,
        equals(0),
        reason: 'Indirect Ack from intermediary should prevent probe failure',
      );
      expect(probed.status, equals(PeerStatus.reachable));

      await intermediarySub.cancel();
      await targetSub.cancel();
      h.stopListening();
    });

    test('performProbeRound with no peers returns immediately', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
      );
      // No peers added

      // Should complete without error or delay
      await h.detector.performProbeRound();
    });

    test('peer removed during active probe does not crash', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
      );
      final peer = h.addPeer('peer1');

      final probeRoundFuture = h.detector.performProbeRound();
      await h.flush();

      h.peerRegistry.removePeer(peer.id, occurredAt: DateTime.now());

      await h.advancePastTimeout();
      await probeRoundFuture;

      expect(h.peerRegistry.getPeer(peer.id), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Health checking
  // ---------------------------------------------------------------------------

  group('Health checking', () {
    test('handleAck updates peer last contact time', () {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      final peerBefore = h.peerRegistry.getPeer(peer.id)!;
      final initialContact = peerBefore.lastContactMs;

      final laterMs = DateTime.now().millisecondsSinceEpoch + 100;
      final ack = Ack(sender: peer.id, sequence: 1);
      h.detector.handleAck(ack, timestampMs: laterMs);

      final peerAfter = h.peerRegistry.getPeer(peer.id)!;
      expect(peerAfter.lastContactMs, equals(laterMs));
      expect(peerAfter.lastContactMs, greaterThan(initialContact));
    });

    test('recordProbeFailure increments failed probe count', () {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      expect(h.peerRegistry.getPeer(peer.id)!.failedProbeCount, equals(0));

      h.detector.recordProbeFailure(peer.id);

      expect(h.peerRegistry.getPeer(peer.id)!.failedProbeCount, equals(1));
    });

    test('transitions to suspected at exact failure threshold', () {
      final h = FailureDetectorTestHarness(failureThreshold: 3);
      final peer = h.addPeer('peer1');

      for (var i = 0; i < 3; i++) {
        h.detector.recordProbeFailure(peer.id);
      }
      h.detector.checkPeerHealth(peer.id, occurredAt: DateTime.now());

      expect(
        h.peerRegistry.getPeer(peer.id)!.status,
        equals(PeerStatus.suspected),
      );
    });

    test('does not transition peer below failure threshold', () {
      final h = FailureDetectorTestHarness(failureThreshold: 3);
      final peer = h.addPeer('peer1');

      h.detector.recordProbeFailure(peer.id);
      h.detector.recordProbeFailure(peer.id);
      h.detector.checkPeerHealth(peer.id, occurredAt: DateTime.now());

      final info = h.peerRegistry.getPeer(peer.id)!;
      expect(info.status, equals(PeerStatus.reachable));
      expect(info.failedProbeCount, equals(2));
    });

    test('does not double-transition already suspected peer', () {
      final h = FailureDetectorTestHarness(failureThreshold: 3);
      final peer = h.addPeer('peer1');

      for (var i = 0; i < 3; i++) {
        h.detector.recordProbeFailure(peer.id);
      }
      h.detector.checkPeerHealth(peer.id, occurredAt: DateTime.now());
      expect(
        h.peerRegistry.getPeer(peer.id)!.status,
        equals(PeerStatus.suspected),
      );

      h.detector.recordProbeFailure(peer.id);
      h.detector.checkPeerHealth(peer.id, occurredAt: DateTime.now());
      expect(
        h.peerRegistry.getPeer(peer.id)!.status,
        equals(PeerStatus.suspected),
      );
    });

    test(
      'transitions suspected peer to unreachable at unreachable threshold',
      () async {
        final h = FailureDetectorTestHarness(
          failureThreshold: 3,
          unreachableThreshold: 6,
          pingTimeout: const Duration(milliseconds: 500),
        );
        final peer = h.addPeer('peer1');

        h.startListening();

        // 3 failures → suspected
        for (var i = 0; i < 3; i++) {
          await h.probeWithTimeout();
        }
        expect(
          h.peerRegistry.getPeer(peer.id)!.status,
          equals(PeerStatus.suspected),
        );

        // 3 more failures (6 total) → unreachable
        for (var i = 0; i < 3; i++) {
          await h.probeWithTimeout();
        }
        expect(
          h.peerRegistry.getPeer(peer.id)!.status,
          equals(PeerStatus.unreachable),
        );

        h.stopListening();
      },
    );

    test(
      'does not transition suspected peer to unreachable below threshold',
      () async {
        final h = FailureDetectorTestHarness(
          failureThreshold: 3,
          unreachableThreshold: 6,
          pingTimeout: const Duration(milliseconds: 500),
        );
        final peer = h.addPeer('peer1');

        h.startListening();

        // 3 failures → suspected
        for (var i = 0; i < 3; i++) {
          await h.probeWithTimeout();
        }
        expect(
          h.peerRegistry.getPeer(peer.id)!.status,
          equals(PeerStatus.suspected),
        );

        // 2 more failures (5 total, below 6) → still suspected
        for (var i = 0; i < 2; i++) {
          await h.probeWithTimeout();
        }
        expect(
          h.peerRegistry.getPeer(peer.id)!.status,
          equals(PeerStatus.suspected),
        );
        expect(h.peerRegistry.getPeer(peer.id)!.failedProbeCount, equals(5));

        h.stopListening();
      },
    );

    test('unreachable peer is not selected for probing', () async {
      final h = FailureDetectorTestHarness(
        failureThreshold: 3,
        unreachableThreshold: 6,
        pingTimeout: const Duration(milliseconds: 500),
      );
      h.addPeer('peer1');

      h.startListening();

      // Drive to unreachable: 6 failures
      for (var i = 0; i < 6; i++) {
        await h.probeWithTimeout();
      }
      expect(
        h.peerRegistry.getPeer(NodeId('peer1'))!.status,
        equals(PeerStatus.unreachable),
      );

      // Unreachable peer should not be selectable
      expect(h.detector.selectRandomPeer(), isNull);

      h.stopListening();
    });

    test(
      'unreachable peer recovers to reachable when contact received',
      () async {
        final h = FailureDetectorTestHarness(
          failureThreshold: 3,
          unreachableThreshold: 6,
          pingTimeout: const Duration(milliseconds: 500),
        );
        final peer = h.addPeer('peer1');

        h.startListening();

        // Drive to unreachable: 6 failures
        for (var i = 0; i < 6; i++) {
          await h.probeWithTimeout();
        }
        expect(
          h.peerRegistry.getPeer(peer.id)!.status,
          equals(PeerStatus.unreachable),
        );

        // Simulate receiving an Ack (e.g., transport reconnection)
        h.detector.handleAck(
          Ack(sender: peer.id, sequence: 999),
          timestampMs: h.timePort.nowMs,
        );

        final recovered = h.peerRegistry.getPeer(peer.id)!;
        expect(recovered.status, equals(PeerStatus.reachable));
        expect(recovered.failedProbeCount, equals(0));

        h.stopListening();
      },
    );

    test('no-ops for unknown peer', () {
      final h = FailureDetectorTestHarness();
      h.detector.checkPeerHealth(NodeId('unknown'), occurredAt: DateTime.now());
    });

    test('suspected peer recovers when it responds to probe', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
        failureThreshold: 3,
      );
      final peer = h.addPeer('peer1');

      h.startListening();

      // Drive peer to suspected state via 3 failed probes
      for (var i = 0; i < 3; i++) {
        await h.probeWithTimeout();
      }

      final suspectedPeer = h.peerRegistry.getPeer(peer.id)!;
      expect(suspectedPeer.status, equals(PeerStatus.suspected));
      expect(suspectedPeer.failedProbeCount, equals(3));

      // Suspected peer is still selected for probing (via probablePeers)
      final selected = h.detector.selectRandomPeer();
      expect(selected, isNotNull);
      expect(selected!.id, equals(peer.id));

      // Peer responds to probe → recovers
      await h.probeWithAck(peer, afterDelay: const Duration(milliseconds: 100));

      final recoveredPeer = h.peerRegistry.getPeer(peer.id)!;
      expect(
        recoveredPeer.status,
        equals(PeerStatus.reachable),
        reason: 'Suspected peer should recover to reachable after Ack',
      );
      expect(
        recoveredPeer.failedProbeCount,
        equals(0),
        reason: 'Failed probe count should reset on recovery',
      );

      h.stopListening();
    });

    test('suspected peer recovery emits PeerStatusChanged event', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
        failureThreshold: 3,
      );
      final peer = h.addPeer('peer1');

      h.startListening();

      // Drive peer to suspected state via 3 failed probes
      for (var i = 0; i < 3; i++) {
        await h.probeWithTimeout();
      }
      expect(
        h.peerRegistry.getPeer(peer.id)!.status,
        equals(PeerStatus.suspected),
      );

      // Clear events from setup phase
      final eventsBefore = h.peerRegistry.uncommittedEvents.length;

      // Peer responds to probe → recovers
      await h.probeWithAck(peer, afterDelay: const Duration(milliseconds: 100));

      final newEvents = h.peerRegistry.uncommittedEvents
          .skip(eventsBefore)
          .toList();
      final statusChanges = newEvents.whereType<PeerStatusChanged>().toList();
      expect(statusChanges, hasLength(1));
      expect(statusChanges.first.oldStatus, equals(PeerStatus.suspected));
      expect(statusChanges.first.newStatus, equals(PeerStatus.reachable));

      h.stopListening();
    });
  });

  // ---------------------------------------------------------------------------
  // Unreachable peer probing
  // ---------------------------------------------------------------------------

  group('Unreachable peer probing', () {
    /// Helper: drives a single peer to unreachable status.
    Future<void> driveToUnreachable(
      FailureDetectorTestHarness h, {
      required int failures,
    }) async {
      for (var i = 0; i < failures; i++) {
        await h.probeWithTimeout();
      }
    }

    test(
      'probes unreachable peer after unreachableProbeInterval rounds',
      () async {
        final h = FailureDetectorTestHarness(
          failureThreshold: 3,
          unreachableThreshold: 6,
          unreachableProbeInterval: 3,
          pingTimeout: const Duration(milliseconds: 500),
        );
        final peer = h.addPeer('peer1');
        final codec = ProtocolCodec();

        h.startListening();

        // Drive to unreachable
        await driveToUnreachable(h, failures: 6);
        expect(
          h.peerRegistry.getPeer(peer.id)!.status,
          equals(PeerStatus.unreachable),
        );

        // Track pings received by the peer
        final pingsReceived = <Ping>[];
        final sub = peer.port.incoming.listen((msg) {
          final decoded = codec.decode(msg.bytes);
          if (decoded is Ping) pingsReceived.add(decoded);
        });

        // Run 3 probe rounds — unreachable probe fires on the 3rd
        // (selectRandomPeer returns null since peer is unreachable,
        // so only the unreachable probe mechanism sends pings)
        for (var i = 0; i < 3; i++) {
          final probeFuture = h.detector.performProbeRound();
          await h.flush();
          await h.advancePastTimeout();
          await probeFuture;
        }

        expect(
          pingsReceived,
          isNotEmpty,
          reason: 'Unreachable peer should receive a Ping after interval',
        );

        await sub.cancel();
        h.stopListening();
      },
    );

    test(
      'unreachable peer recovers when it responds to periodic probe',
      () async {
        final h = FailureDetectorTestHarness(
          failureThreshold: 3,
          unreachableThreshold: 6,
          unreachableProbeInterval: 3,
          pingTimeout: const Duration(milliseconds: 500),
        );
        final peer = h.addPeer('peer1');

        h.startListening();

        // Drive to unreachable
        await driveToUnreachable(h, failures: 6);
        expect(
          h.peerRegistry.getPeer(peer.id)!.status,
          equals(PeerStatus.unreachable),
        );

        // Run probe rounds until the unreachable probe fires (round 3).
        // On rounds 1 & 2, just let them pass (no regular peer to probe).
        for (var i = 0; i < 2; i++) {
          final probeFuture = h.detector.performProbeRound();
          await h.flush();
          await h.advancePastTimeout();
          await probeFuture;
        }

        // Round 3: unreachable probe fires. Intercept the Ping and respond.
        // After recovery, the peer is reachable again so the regular probe
        // in performProbeRound() will also fire — advance time to let it
        // complete.
        final pingFuture = peer.capturePing(h.codec);
        final probeFuture = h.detector.performProbeRound();
        final ping = await pingFuture;
        await h.sendAck(
          peer,
          ping.sequence,
          afterDelay: const Duration(milliseconds: 50),
        );
        // Advance time for the regular probe round that follows recovery
        await h.flush();
        await h.advancePastTimeout();
        await probeFuture;

        expect(
          h.peerRegistry.getPeer(peer.id)!.status,
          equals(PeerStatus.reachable),
        );
        // failedProbeCount may be > 0 if the regular probe that followed
        // recovery timed out; the important assertion is the status.

        h.stopListening();
      },
    );

    test('unreachable probe does not record failure on timeout', () async {
      final h = FailureDetectorTestHarness(
        failureThreshold: 3,
        unreachableThreshold: 6,
        unreachableProbeInterval: 3,
        pingTimeout: const Duration(milliseconds: 500),
      );
      h.addPeer('peer1');

      h.startListening();

      // Drive to unreachable
      await driveToUnreachable(h, failures: 6);
      final failedCountBefore = h.peerRegistry
          .getPeer(NodeId('peer1'))!
          .failedProbeCount;

      // Run 3 rounds to trigger unreachable probe (no Ack sent → timeout)
      for (var i = 0; i < 3; i++) {
        final probeFuture = h.detector.performProbeRound();
        await h.flush();
        await h.advancePastTimeout();
        await probeFuture;
      }

      final failedCountAfter = h.peerRegistry
          .getPeer(NodeId('peer1'))!
          .failedProbeCount;
      expect(
        failedCountAfter,
        equals(failedCountBefore),
        reason: 'Unreachable probe should not increment failedProbeCount',
      );

      h.stopListening();
    });

    test('round-robins across multiple unreachable peers', () async {
      final h = FailureDetectorTestHarness(
        failureThreshold: 3,
        unreachableThreshold: 6,
        unreachableProbeInterval: 3,
        pingTimeout: const Duration(milliseconds: 500),
      );
      final peer1 = h.addPeer('peer1');
      final peer2 = h.addPeer('peer2');
      final codec = ProtocolCodec();

      h.startListening();

      // Drive both to unreachable via direct registry manipulation
      for (final peerId in [peer1.id, peer2.id]) {
        h.peerRegistry.updatePeerStatus(
          peerId,
          PeerStatus.suspected,
          occurredAt: DateTime.now(),
        );
        h.peerRegistry.updatePeerStatus(
          peerId,
          PeerStatus.unreachable,
          occurredAt: DateTime.now(),
        );
      }
      expect(
        h.peerRegistry.getPeer(peer1.id)!.status,
        equals(PeerStatus.unreachable),
      );
      expect(
        h.peerRegistry.getPeer(peer2.id)!.status,
        equals(PeerStatus.unreachable),
      );

      // Track which peers receive pings
      final peer1Pings = <Ping>[];
      final peer2Pings = <Ping>[];
      final sub1 = peer1.port.incoming.listen((msg) {
        final decoded = codec.decode(msg.bytes);
        if (decoded is Ping) peer1Pings.add(decoded);
      });
      final sub2 = peer2.port.incoming.listen((msg) {
        final decoded = codec.decode(msg.bytes);
        if (decoded is Ping) peer2Pings.add(decoded);
      });

      // Run 6 rounds to trigger 2 unreachable probes (at rounds 3 and 6)
      for (var i = 0; i < 6; i++) {
        final probeFuture = h.detector.performProbeRound();
        await h.flush();
        await h.advancePastTimeout();
        await probeFuture;
      }

      expect(
        peer1Pings,
        isNotEmpty,
        reason: 'peer1 should receive an unreachable probe',
      );
      expect(
        peer2Pings,
        isNotEmpty,
        reason: 'peer2 should receive an unreachable probe',
      );

      await sub1.cancel();
      await sub2.cancel();
      h.stopListening();
    });

    test(
      'recovers unreachable peer via indirect ping through intermediary',
      () async {
        final h = FailureDetectorTestHarness(
          failureThreshold: 3,
          unreachableThreshold: 6,
          unreachableProbeInterval: 3,
          pingTimeout: const Duration(milliseconds: 500),
        );
        final target = h.addPeer('target');
        final intermediary = h.addPeer('intermediary');
        final codec = ProtocolCodec();

        h.startListening();

        // Drive target to unreachable via direct registry manipulation
        // (avoids random peer selection issues with 2 peers).
        h.peerRegistry.updatePeerStatus(
          target.id,
          PeerStatus.suspected,
          occurredAt: DateTime.now(),
        );
        h.peerRegistry.updatePeerStatus(
          target.id,
          PeerStatus.unreachable,
          occurredAt: DateTime.now(),
        );
        expect(
          h.peerRegistry.getPeer(target.id)!.status,
          equals(PeerStatus.unreachable),
        );

        // Intermediary handles PingReq: pings target, forwards Ack back.
        intermediary.port.incoming.listen((msg) async {
          final decoded = codec.decode(msg.bytes);
          if (decoded is PingReq) {
            final ping = Ping(
              sender: intermediary.id,
              sequence: decoded.sequence,
            );
            await intermediary.port.send(decoded.target, codec.encode(ping));
          } else if (decoded is Ack) {
            final forwardedAck = Ack(
              sender: intermediary.id,
              sequence: decoded.sequence,
            );
            await intermediary.port.send(
              h.localNode,
              codec.encode(forwardedAck),
            );
          }
        });

        // Target responds to pings from intermediary only (not from local),
        // forcing recovery through the indirect path.
        target.port.incoming.listen((msg) async {
          final decoded = codec.decode(msg.bytes);
          if (decoded is Ping && msg.sender == intermediary.id) {
            final ack = Ack(sender: target.id, sequence: decoded.sequence);
            await target.port.send(msg.sender, codec.encode(ack));
          }
        });

        // Run 3 rounds to trigger unreachable probe.
        // On the firing round, the unreachable probe does:
        //   1. Direct Ping → timeout (needs 1 time advance)
        //   2. Indirect PingReq → intermediary relays → Ack (needs 1 more)
        // Then the regular probe may also fire if recovery succeeded.
        for (var i = 0; i < 3; i++) {
          final probeFuture = h.detector.performProbeRound();
          await h.flush();
          await h.advancePastTimeout();
          await h.flush();
          await h.advancePastTimeout();
          await probeFuture;
        }

        expect(
          h.peerRegistry.getPeer(target.id)!.status,
          equals(PeerStatus.reachable),
          reason:
              'Target should recover via indirect ping through intermediary',
        );

        h.stopListening();
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  group('Lifecycle', () {
    final codec = ProtocolCodec();

    test('start begins periodic probes', () {
      final h = FailureDetectorTestHarness();
      h.detector.start();
      expect(h.detector.isRunning, isTrue);
    });

    test('stop cancels probes', () {
      final h = FailureDetectorTestHarness();
      h.detector.start();
      expect(h.detector.isRunning, isTrue);

      h.detector.stop();
      expect(h.detector.isRunning, isFalse);
    });

    test('start() twice does not create duplicate timers', () {
      final h = FailureDetectorTestHarness();

      h.detector.start();
      expect(h.detector.isRunning, isTrue);

      h.detector.start();
      expect(h.detector.isRunning, isTrue);
      expect(h.timePort.pendingDelayCount, equals(1));

      h.detector.stop();
    });

    test('stop() twice does not throw', () {
      final h = FailureDetectorTestHarness();

      h.detector.start();
      h.detector.stop();
      expect(h.detector.isRunning, isFalse);

      h.detector.stop();
      expect(h.detector.isRunning, isFalse);
    });

    test('stop() before start() does not throw', () {
      final h = FailureDetectorTestHarness();

      h.detector.stop();
      expect(h.detector.isRunning, isFalse);
    });

    test('stopListening() before startListening() does not throw', () {
      final h = FailureDetectorTestHarness();
      h.stopListening();
    });

    test('startListening() twice does not duplicate subscriptions', () async {
      final h = FailureDetectorTestHarness();
      final peer = h.addPeer('peer1');

      final acks = <Ack>[];
      final peerSub = peer.port.incoming.listen((msg) {
        final decoded = codec.decode(msg.bytes);
        if (decoded is Ack) acks.add(decoded);
      });

      h.startListening();
      h.startListening();

      await h.sendPing(peer, sequence: 1);
      await h.flush();

      expect(acks.length, greaterThanOrEqualTo(1));

      await peerSub.cancel();
      h.stopListening();
    });

    test('stop() during active probe does not crash', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
      );
      h.addPeer('peer1');

      // Start a probe but stop the detector mid-flight
      final probeRoundFuture = h.detector.performProbeRound();
      await h.flush();

      h.detector.stop();
      expect(h.detector.isRunning, isFalse);

      // Let the probe's timeouts resolve
      await h.advancePastTimeout();
      await probeRoundFuture;

      // Detector should remain stopped, no crash
      expect(h.detector.isRunning, isFalse);
    });

    test('concurrent performProbeRound calls do not crash', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
      );
      h.addPeer('peer1');

      // Launch two probe rounds concurrently
      final probe1 = h.detector.performProbeRound();
      final probe2 = h.detector.performProbeRound();
      await h.flush();

      // Let both probes timeout
      await h.advancePastTimeout();
      await probe1;
      await probe2;

      // Both complete without crash; failures may be recorded
      final peer = h.peerRegistry.getPeer(NodeId('peer1'))!;
      expect(peer.failedProbeCount, greaterThanOrEqualTo(1));
    });

    test('probe scheduling continues after error', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 100),
        probeInterval: const Duration(milliseconds: 200),
      );
      h.addPeer('peer1');

      h.detector.start();

      // First probe interval fires → probe round runs (and fails/times out)
      await h.timePort.advance(const Duration(milliseconds: 201));
      await h.flush();
      await h.timePort.advance(const Duration(milliseconds: 101));
      await h.timePort.advance(const Duration(milliseconds: 101));
      await h.flush();

      // Second probe interval — scheduling should have continued
      await h.timePort.advance(const Duration(milliseconds: 201));
      await h.flush();

      // Verify the detector is still running and scheduling probes
      expect(h.detector.isRunning, isTrue);
      expect(h.timePort.pendingDelayCount, greaterThan(0));

      // Clean up
      await h.timePort.advance(const Duration(milliseconds: 101));
      await h.timePort.advance(const Duration(milliseconds: 101));
      h.detector.stop();
    });

    test('restart after stop resumes probing', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 200),
        probeInterval: const Duration(milliseconds: 500),
      );
      final peer = h.addPeer('peer1');

      h.startListening();

      h.detector.start();
      expect(h.detector.isRunning, isTrue);

      h.detector.stop();
      expect(h.detector.isRunning, isFalse);

      h.detector.start();
      expect(h.detector.isRunning, isTrue);

      final pingsReceived = <Ping>[];
      final peerSub = peer.port.incoming.listen((msg) {
        final decoded = codec.decode(msg.bytes);
        if (decoded is Ping) pingsReceived.add(decoded);
      });

      await h.timePort.advance(const Duration(milliseconds: 501));
      await h.flush();

      expect(
        pingsReceived,
        isNotEmpty,
        reason: 'Probing should resume after stop/start cycle',
      );

      // Clean up — advance past timeouts
      await h.timePort.advance(const Duration(milliseconds: 201));
      await h.timePort.advance(const Duration(milliseconds: 201));

      await peerSub.cancel();
      h.detector.stop();
      h.stopListening();
    });
  });
}
