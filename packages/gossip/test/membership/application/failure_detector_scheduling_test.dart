import 'package:gossip/src/membership/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/membership/application/failure_detector.dart';
import 'package:gossip/src/membership/infrastructure/membership_message_codec.dart';
import 'package:test/test.dart';

import '../../support/failing_delay_time_port.dart';
import 'failure_detector_test_harness.dart';

void main() {
  group('FailureDetector scheduling', () {
    test(
      'stop() then start() within one interval does not fork the probe loop',
      () async {
        final h = FailureDetectorTestHarness(
          probeInterval: const Duration(milliseconds: 100),
          pingTimeout: const Duration(milliseconds: 50),
        );

        h.detector.start(); // schedules callback #1
        h.detector.stop();
        h.detector.start(); // schedules callback #2; #1 must become stale

        // Both scheduled callbacks are in flight.
        expect(h.timePort.pendingDelayCount, equals(2));

        // Fire both. Only the live loop may run a round and reschedule;
        // the stale pre-stop callback must not spawn a second chain.
        // 130ms > the 100ms interval + its max +20% jitter, so the round
        // always fires (but not far enough to fire the reschedule too).
        await h.timePort.advance(const Duration(milliseconds: 130));
        await flushMicrotasks();

        expect(
          h.timePort.pendingDelayCount,
          equals(1),
          reason: 'exactly one probe loop must survive a stop/start cycle',
        );

        h.detector.stop();
      },
    );

    test(
      'repeated stop/start cycles never accumulate extra probe loops',
      () async {
        final h = FailureDetectorTestHarness(
          probeInterval: const Duration(milliseconds: 100),
          pingTimeout: const Duration(milliseconds: 50),
        );

        for (var i = 0; i < 3; i++) {
          h.detector.start();
          h.detector.stop();
        }
        h.detector.start();

        // Let several intervals elapse; a single loop reschedules itself
        // exactly once per interval.
        for (var i = 0; i < 3; i++) {
          // 130ms > the 100ms interval + its max +20% jitter, so the round
        // always fires (but not far enough to fire the reschedule too).
        await h.timePort.advance(const Duration(milliseconds: 130));
          await flushMicrotasks();
          expect(
            h.timePort.pendingDelayCount,
            equals(1),
            reason: 'interval ${i + 1}: only one loop may be scheduled',
          );
        }

        h.detector.stop();
      },
    );

    test(
      'delay failure emits an error and stops the loop instead of dying '
      'silently',
      () async {
        final timePort = FailingDelayTimePort();
        final localNode = NodeId('local');
        final errors = <SyncError>[];
        final detector = FailureDetector(
          codec: MembershipMessageCodec(),
          localNode: localNode,
          peerRegistry: PeerRegistry(
            localNode: localNode,
          ),
          timePort: timePort,
          messagePort: InMemoryMessagePort(localNode, InMemoryMessageBus()),
          onError: errors.add,
          probeInterval: const Duration(milliseconds: 100),
          pingTimeout: const Duration(milliseconds: 50),
        );

        timePort.failNextDelay = true;
        detector.start();

        // Let the failed delay future propagate.
        await Future.delayed(Duration.zero);
        await Future.delayed(Duration.zero);

        expect(
          errors,
          isNotEmpty,
          reason: 'a scheduling failure must surface via ErrorCallback',
        );
        expect(
          detector.isRunning,
          isFalse,
          reason: 'a dead loop must not report itself as running',
        );
      },
    );
  });
}

/// Yields the microtask queue a few times so async round chains settle.
Future<void> flushMicrotasks([int count = 3]) async {
  for (var i = 0; i < count; i++) {
    await Future.delayed(Duration.zero);
  }
}
