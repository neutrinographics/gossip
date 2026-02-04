import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/errors/sync_error.dart';
import 'package:gossip/src/domain/events/domain_event.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/ports/message_port.dart';
import 'package:gossip/src/protocol/failure_detector.dart';
import 'package:gossip/src/protocol/messages/ack.dart';
import 'package:gossip/src/protocol/messages/ping.dart';
import 'package:gossip/src/protocol/messages/ping_req.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';
import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

/// A MessagePort that throws on send, simulating transport failure.
class FailingSendMessagePort implements MessagePort {
  final InMemoryMessagePort _delegate;
  bool shouldFail = true;

  FailingSendMessagePort(this._delegate);

  @override
  Future<void> send(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
    if (shouldFail) {
      throw Exception('Transport send failed');
    }
    await _delegate.send(destination, bytes, priority: priority);
  }

  @override
  Stream<IncomingMessage> get incoming => _delegate.incoming;

  @override
  Future<void> close() => _delegate.close();

  @override
  int pendingSendCount(NodeId peer) => _delegate.pendingSendCount(peer);

  @override
  int get totalPendingSendCount => _delegate.totalPendingSendCount;
}

void main() {
  final codec = ProtocolCodec();

  // ---------------------------------------------------------------------------
  // Intermediary role (_handlePingReq)
  // ---------------------------------------------------------------------------

  group('Intermediary role (_handlePingReq)', () {
    late FailureDetectorTestHarness h;
    late TestPeer prober;
    late TestPeer target;

    setUp(() {
      h = FailureDetectorTestHarness(
        localName: 'intermediary',
        pingTimeout: const Duration(milliseconds: 500),
      );
      prober = h.addPeer('prober');
      target = h.addPeer('target');
    });

    test('forwards Ack back to prober when target responds', () async {
      h.startListening();

      // Target auto-responds with Ack
      final targetSub = target.port.incoming.listen((msg) {
        final decoded = codec.decode(msg.bytes);
        if (decoded is Ping) {
          final ack = Ack(sender: target.id, sequence: decoded.sequence);
          target.port.send(h.localNode, codec.encode(ack));
        }
      });

      // Capture messages arriving at prober
      final proberMessages = <dynamic>[];
      final proberSub = prober.port.incoming.listen((msg) {
        proberMessages.add(codec.decode(msg.bytes));
      });

      // Prober sends PingReq to intermediary
      final pingReq = PingReq(
        sender: prober.id,
        sequence: 42,
        target: target.id,
      );
      await prober.port.send(h.localNode, codec.encode(pingReq));

      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(proberMessages, hasLength(1));
      expect(proberMessages.first, isA<Ack>());
      final forwardedAck = proberMessages.first as Ack;
      expect(forwardedAck.sender, equals(h.localNode));
      expect(forwardedAck.sequence, equals(42));

      await targetSub.cancel();
      await proberSub.cancel();
      h.stopListening();
    });

    test('does not forward Ack when target does not respond', () async {
      h.startListening();

      final proberMessages = <dynamic>[];
      final proberSub = prober.port.incoming.listen((msg) {
        proberMessages.add(codec.decode(msg.bytes));
      });

      final pingReq = PingReq(
        sender: prober.id,
        sequence: 42,
        target: target.id,
      );
      await prober.port.send(h.localNode, codec.encode(pingReq));

      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      // Advance past intermediary timeout (200ms)
      await h.timePort.advance(const Duration(milliseconds: 201));
      await Future.delayed(Duration.zero);

      expect(proberMessages, isEmpty);

      await proberSub.cancel();
      h.stopListening();
    });

    test('sends Ping to the correct target', () async {
      h.startListening();

      final targetMessages = <dynamic>[];
      final targetSub = target.port.incoming.listen((msg) {
        targetMessages.add(codec.decode(msg.bytes));
      });

      final pingReq = PingReq(
        sender: prober.id,
        sequence: 99,
        target: target.id,
      );
      await prober.port.send(h.localNode, codec.encode(pingReq));

      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(targetMessages, hasLength(1));
      expect(targetMessages.first, isA<Ping>());
      final ping = targetMessages.first as Ping;
      expect(ping.sender, equals(h.localNode));
      expect(ping.sequence, greaterThan(0));

      // Clean up — advance past timeout so _handlePingReq completes
      await h.timePort.advance(const Duration(milliseconds: 201));

      await targetSub.cancel();
      h.stopListening();
    });
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  group('Error handling', () {
    late FailureDetectorTestHarness h;
    late TestPeer peer;

    setUp(() {
      h = FailureDetectorTestHarness();
      peer = h.addPeer('peer1');
    });

    test('emits messageCorrupted error for malformed message bytes', () async {
      h.startListening();

      final garbageBytes = Uint8List.fromList([255, 0, 1, 2, 3]);
      await peer.port.send(h.localNode, garbageBytes);
      await Future.delayed(Duration.zero);

      expect(h.errors, hasLength(1));
      expect(h.errors.first, isA<PeerSyncError>());
      final error = h.errors.first as PeerSyncError;
      expect(error.type, equals(SyncErrorType.messageCorrupted));
      expect(error.peer, equals(peer.id));

      h.stopListening();
    });

    test('emits messageCorrupted error for empty message bytes', () async {
      h.startListening();

      await peer.port.send(h.localNode, Uint8List(0));
      await Future.delayed(Duration.zero);

      expect(h.errors, hasLength(1));
      expect(h.errors.first, isA<PeerSyncError>());
      final error = h.errors.first as PeerSyncError;
      expect(error.type, equals(SyncErrorType.messageCorrupted));

      h.stopListening();
    });

    test('emits peerUnreachable error when transport send fails', () async {
      final localNode = NodeId('local');
      final peerNode = NodeId('peer1');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      peerRegistry.addPeer(peerNode, occurredAt: DateTime.now());

      final timePort = InMemoryTimePort();
      final bus = InMemoryMessageBus();
      final localPort = InMemoryMessagePort(localNode, bus);
      final failingPort = FailingSendMessagePort(localPort);
      final errors = <SyncError>[];

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: failingPort,
        onError: errors.add,
        pingTimeout: const Duration(milliseconds: 500),
      );

      final probeFuture = detector.probeNewPeer(peerNode);
      await Future.delayed(Duration.zero);

      expect(errors, hasLength(1));
      final error = errors.first as PeerSyncError;
      expect(error.type, equals(SyncErrorType.peerUnreachable));
      expect(error.peer, equals(peerNode));

      await timePort.advance(const Duration(milliseconds: 501));
      final result = await probeFuture;
      expect(result, isFalse);
    });

    test('emits protocolError when probe round throws', () async {
      final localNode = NodeId('local');
      final peerNode = NodeId('peer1');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      peerRegistry.addPeer(peerNode, occurredAt: DateTime.now());

      final timePort = InMemoryTimePort();
      final bus = InMemoryMessageBus();
      final localPort = InMemoryMessagePort(localNode, bus);
      final failingPort = FailingSendMessagePort(localPort);
      final errors = <SyncError>[];

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: failingPort,
        onError: errors.add,
        pingTimeout: const Duration(milliseconds: 100),
        probeInterval: const Duration(milliseconds: 200),
      );

      detector.start();

      await timePort.advance(const Duration(milliseconds: 201));
      await timePort.advance(const Duration(milliseconds: 101));
      await timePort.advance(const Duration(milliseconds: 101));

      expect(errors, isNotEmpty);
      expect(errors.first, isA<PeerSyncError>());

      detector.stop();
    });

    test('Ack response send failure emits error but does not crash', () async {
      final localNode = NodeId('local');
      final peerNode = NodeId('peer1');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      peerRegistry.addPeer(peerNode, occurredAt: DateTime.now());

      final timePort = InMemoryTimePort();
      final bus = InMemoryMessageBus();
      final localPort = InMemoryMessagePort(localNode, bus);
      final peerPort = InMemoryMessagePort(peerNode, bus);
      final failingPort = FailingSendMessagePort(localPort);
      final errors = <SyncError>[];

      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timePort,
        messagePort: failingPort,
        onError: errors.add,
      );
      detector.startListening();

      final ping = Ping(sender: peerNode, sequence: 10);
      await peerPort.send(localNode, codec.encode(ping));
      await Future.delayed(Duration.zero);

      expect(errors, hasLength(1));
      final error = errors.first as PeerSyncError;
      expect(error.type, equals(SyncErrorType.peerUnreachable));

      detector.stopListening();
    });
  });

  // ---------------------------------------------------------------------------
  // handleAck edge cases
  // ---------------------------------------------------------------------------

  group('handleAck edge cases', () {
    late FailureDetectorTestHarness h;
    late TestPeer peer;

    setUp(() {
      h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
      );
      peer = h.addPeer('peer1');
    });

    test('unrecognized sequence number is ignored without error', () {
      final ack = Ack(sender: peer.id, sequence: 9999);
      h.detector.handleAck(ack, timestampMs: h.timePort.nowMs);

      expect(h.rttTracker.hasReceivedSamples, isFalse);
    });

    test(
      'duplicate Ack for already-completed pending ping is ignored',
      () async {
        h.startListening();

        final pingFuture = h.expectPing(peer);
        final probeFuture = h.detector.probeNewPeer(peer.id);
        final ping = await pingFuture;

        await h.sendAck(
          peer,
          ping.sequence,
          afterDelay: const Duration(milliseconds: 100),
        );
        await probeFuture;

        expect(h.rttTracker.sampleCount, equals(1));

        // Duplicate Ack — pending ping already cleaned up
        h.detector.handleAck(
          Ack(sender: peer.id, sequence: ping.sequence),
          timestampMs: h.timePort.nowMs,
        );

        expect(h.rttTracker.sampleCount, equals(1));
        h.stopListening();
      },
    );

    test(
      'Ack still updates peer contact time even without matching pending ping',
      () {
        final before = h.peerRegistry.getPeer(peer.id)!.lastContactMs;
        final laterMs = before + 5000;

        final ack = Ack(sender: peer.id, sequence: 9999);
        h.detector.handleAck(ack, timestampMs: laterMs);

        final after = h.peerRegistry.getPeer(peer.id)!.lastContactMs;
        expect(after, equals(laterMs));
      },
    );

    test('zero RTT sample is not recorded', () async {
      h.startListening();

      final pingFuture = h.expectPing(peer);
      final probeFuture = h.detector.probeNewPeer(peer.id);
      final ping = await pingFuture;

      // Send Ack immediately — no time advance, so RTT = 0ms
      await h.sendAck(peer, ping.sequence);
      await probeFuture;

      expect(h.rttTracker.hasReceivedSamples, isFalse);
      h.stopListening();
    });
  });

  // ---------------------------------------------------------------------------
  // Health checking edge cases
  // ---------------------------------------------------------------------------

  group('checkPeerHealth edge cases', () {
    late FailureDetectorTestHarness h;

    setUp(() {
      h = FailureDetectorTestHarness(failureThreshold: 3);
    });

    test('does not transition peer below failure threshold', () {
      final peer = h.addPeer('peer1');

      h.detector.recordProbeFailure(peer.id);
      h.detector.recordProbeFailure(peer.id);
      h.detector.checkPeerHealth(peer.id, occurredAt: DateTime.now());

      final info = h.peerRegistry.getPeer(peer.id)!;
      expect(info.status, equals(PeerStatus.reachable));
      expect(info.failedProbeCount, equals(2));
    });

    test('no-ops for unknown peer', () {
      h.detector.checkPeerHealth(NodeId('unknown'), occurredAt: DateTime.now());
    });

    test('does not double-transition already suspected peer', () {
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

    test('transitions at exact threshold boundary', () {
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
  });

  // ---------------------------------------------------------------------------
  // Lifecycle idempotency
  // ---------------------------------------------------------------------------

  group('Lifecycle idempotency', () {
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

      final ping = Ping(sender: peer.id, sequence: 1);
      await peer.port.send(h.localNode, codec.encode(ping));
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(acks.length, greaterThanOrEqualTo(1));

      await peerSub.cancel();
      h.stopListening();
    });
  });

  // ---------------------------------------------------------------------------
  // Incoming message metrics recording
  // ---------------------------------------------------------------------------

  group('Incoming message metrics recording', () {
    late FailureDetectorTestHarness h;
    late TestPeer peer;

    setUp(() {
      h = FailureDetectorTestHarness();
      peer = h.addPeer('peer1');
    });

    test('records received message metrics for incoming Ping', () async {
      h.startListening();

      final before = h.peerRegistry.getPeer(peer.id)!.metrics;
      expect(before.messagesReceived, equals(0));

      final ping = Ping(sender: peer.id, sequence: 1);
      final pingBytes = codec.encode(ping);
      await peer.port.send(h.localNode, pingBytes);
      await Future.delayed(Duration.zero);

      final after = h.peerRegistry.getPeer(peer.id)!.metrics;
      expect(after.messagesReceived, equals(1));
      expect(after.bytesReceived, equals(pingBytes.length));

      h.stopListening();
    });

    test('records received message metrics for incoming Ack', () async {
      h.startListening();

      final ack = Ack(sender: peer.id, sequence: 1);
      final ackBytes = codec.encode(ack);
      await peer.port.send(h.localNode, ackBytes);
      await Future.delayed(Duration.zero);

      final after = h.peerRegistry.getPeer(peer.id)!.metrics;
      expect(after.messagesReceived, equals(1));
      expect(after.bytesReceived, equals(ackBytes.length));

      h.stopListening();
    });

    test('records sent message metrics when sending Ping', () async {
      h.startListening();

      final before = h.peerRegistry.getPeer(peer.id)!.metrics;
      expect(before.messagesSent, equals(0));

      final probeFuture = h.detector.probeNewPeer(peer.id);
      await Future.delayed(Duration.zero);

      await h.timePort.advance(const Duration(seconds: 4));
      await probeFuture;

      final after = h.peerRegistry.getPeer(peer.id)!.metrics;
      expect(after.messagesSent, greaterThanOrEqualTo(1));

      h.stopListening();
    });

    test('records metrics even for malformed messages', () async {
      h.startListening();

      final garbageBytes = Uint8List.fromList([255, 0, 1, 2, 3]);
      await peer.port.send(h.localNode, garbageBytes);
      await Future.delayed(Duration.zero);

      final after = h.peerRegistry.getPeer(peer.id)!.metrics;
      expect(after.messagesReceived, equals(1));
      expect(after.bytesReceived, equals(garbageBytes.length));

      expect(h.errors, hasLength(1));

      h.stopListening();
    });
  });

  // ---------------------------------------------------------------------------
  // Sequence number collision in intermediary role
  // ---------------------------------------------------------------------------

  group('Intermediary sequence number collision', () {
    test(
      'PingReq with colliding sequence does not overwrite local pending ping',
      () async {
        final h = FailureDetectorTestHarness(
          localName: 'intermediary-B',
          pingTimeout: const Duration(milliseconds: 500),
        );
        final prober = h.addPeer('prober-A');
        final target = h.addPeer('target-C');

        h.startListening();

        // Capture the Ping that B sends to C via probeNewPeer
        final localPingFuture = h.expectPing(target);
        final probeFuture = h.detector.probeNewPeer(target.id);
        final localPing = await localPingFuture;

        final collidingSeq = localPing.sequence;

        // A sends PingReq to B with the SAME sequence number.
        // Buggy code would overwrite _pendingPings[seq], orphaning
        // probeNewPeer's completer.
        final pingReq = PingReq(
          sender: prober.id,
          sequence: collidingSeq,
          target: target.id,
        );
        await prober.port.send(h.localNode, codec.encode(pingReq));

        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        // C responds to B's original Ping
        await h.timePort.advance(const Duration(milliseconds: 100));
        final ack = Ack(sender: target.id, sequence: collidingSeq);
        await target.port.send(h.localNode, codec.encode(ack));
        await Future.delayed(Duration.zero);

        // Advance past probeNewPeer's timeout
        await h.timePort.advance(const Duration(milliseconds: 500));

        final gotAck = await probeFuture;

        expect(
          gotAck,
          isTrue,
          reason:
              'probeNewPeer Ack should match the local pending ping, '
              'not be stolen by the PingReq handler',
        );

        expect(
          h.rttTracker.hasReceivedSamples,
          isTrue,
          reason:
              'RTT should be recorded for the local probe, '
              'not lost due to PingReq collision',
        );

        // Clean up — advance past intermediary timeout for PingReq handler
        await h.timePort.advance(const Duration(milliseconds: 201));
        h.stopListening();
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Additional corner cases
  // ---------------------------------------------------------------------------

  group('Corner cases', () {
    test('peer removed during active probe does not crash', () async {
      final h = FailureDetectorTestHarness(
        pingTimeout: const Duration(milliseconds: 500),
      );
      final peer = h.addPeer('peer1');

      final probeRoundFuture = h.detector.performProbeRound();
      await Future.delayed(Duration.zero);

      h.peerRegistry.removePeer(peer.id, occurredAt: DateTime.now());

      await h.advancePastTimeout();
      await probeRoundFuture;

      expect(h.peerRegistry.getPeer(peer.id), isNull);
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
      await Future.delayed(Duration.zero);

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
