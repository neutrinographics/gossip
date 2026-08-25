import 'dart:async';

import 'package:gossip/src/shared/domain/services/generation_scheduler.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:test/test.dart';

import '../../../support/failing_delay_time_port.dart';

void main() {
  group('GenerationScheduler', () {
    test('ticks fire after nextDelay elapses and reschedule after the tick '
        'completes', () async {
      // Part A — Arrange: a scheduler whose tick just counts.
      const interval = Duration(milliseconds: 100);
      final timePort = InMemoryTimePort();
      final tickErrors = <Object>[];
      final schedulingErrors = <Object>[];
      var tickCount = 0;
      final scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () => interval,
        tick: () async => tickCount++,
        onTickError: (error, stackTrace) => tickErrors.add(error),
        onSchedulingError: (error, stackTrace) => schedulingErrors.add(error),
      );

      // Act: let the first interval elapse.
      scheduler.start();
      await timePort.advance(interval);
      await pumpEventQueue();

      // Assert: exactly one tick fired.
      expect(tickCount, equals(1));

      // Act: let a second interval elapse.
      await timePort.advance(interval);
      await pumpEventQueue();

      // Assert: the loop rescheduled after the first tick settled, so a
      // second tick fires too.
      expect(tickCount, equals(2));
      expect(tickErrors, isEmpty);
      expect(schedulingErrors, isEmpty);

      scheduler.stop();

      // Part B — Arrange: a scheduler whose tick is gated so it never
      // settles on its own, on a fresh clock.
      final gatedTimePort = InMemoryTimePort();
      final gate = Completer<void>();
      var startedCount = 0;
      final gatedScheduler = GenerationScheduler(
        timePort: gatedTimePort,
        nextDelay: () => interval,
        tick: () async {
          startedCount++;
          await gate.future;
        },
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
      );

      // Act: advance far past two intervals while the first tick is
      // still gated (in flight, never completing).
      gatedScheduler.start();
      await gatedTimePort.advance(interval * 2);
      await pumpEventQueue();

      // Assert: the second interval's delay can only be scheduled once
      // the in-flight tick settles and reschedules — so the tick body
      // must have started only once, never twice, no matter how far
      // time advances underneath it.
      expect(
        startedCount,
        equals(1),
        reason:
            'reschedule happens only after the tick settles, so an '
            'in-flight tick must block the next interval from being '
            'scheduled at all (the anti-overlap property)',
      );

      gate.complete();
      await pumpEventQueue();
      gatedScheduler.stop();
    });

    test('nextDelay is re-evaluated for every cycle', () async {
      // Arrange: the first cycle waits 100ms, every cycle after waits
      // 200ms — nextDelay must be called fresh each time, not cached.
      final timePort = InMemoryTimePort();
      final delays = [
        const Duration(milliseconds: 100),
        const Duration(milliseconds: 200),
      ];
      var nextDelayCalls = 0;
      var tickCount = 0;
      final scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () {
          final delay = delays[nextDelayCalls.clamp(0, delays.length - 1)];
          nextDelayCalls++;
          return delay;
        },
        tick: () async => tickCount++,
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
      );

      // Act: the first 100ms elapses.
      scheduler.start();
      await timePort.advance(const Duration(milliseconds: 100));
      await pumpEventQueue();

      // Assert: the first cycle used the first nextDelay() value.
      expect(tickCount, equals(1));

      // Act: only 100 of the second cycle's 200ms have elapsed.
      await timePort.advance(const Duration(milliseconds: 100));
      await pumpEventQueue();

      // Assert: no tick yet — the second cycle re-evaluated nextDelay()
      // and got 200ms, not another 100ms.
      expect(tickCount, equals(1));

      // Act: the remaining 100ms of the second cycle's 200ms delay elapses.
      await timePort.advance(const Duration(milliseconds: 100));
      await pumpEventQueue();

      // Assert: the second tick now fires.
      expect(tickCount, equals(2));

      scheduler.stop();
    });

    test('stop() makes the scheduled tick stale', () async {
      // Arrange
      final timePort = InMemoryTimePort();
      var tickCount = 0;
      final scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () => const Duration(milliseconds: 100),
        tick: () async => tickCount++,
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
      );

      // Act: start then immediately stop, before the interval elapses.
      scheduler.start();
      scheduler.stop();
      await timePort.advance(const Duration(milliseconds: 500));
      await pumpEventQueue();

      // Assert: the already-scheduled delay fires (fake time doesn't care
      // it was stopped) but its callback recognizes the stale generation
      // and neither ticks nor reschedules.
      expect(tickCount, equals(0));
      expect(scheduler.isRunning, isFalse);
    });

    test('stop() during an in-flight tick prevents the reschedule', () async {
      // Arrange: a tick gated on a Completer so it can be held in flight.
      final timePort = InMemoryTimePort();
      final gate = Completer<void>();
      var tickCount = 0;
      final scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () => const Duration(milliseconds: 100),
        tick: () async {
          tickCount++;
          await gate.future;
        },
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
      );

      // Act: let the first tick start and hold it in flight.
      scheduler.start();
      await timePort.advance(const Duration(milliseconds: 100));
      await pumpEventQueue();
      expect(
        tickCount,
        equals(1),
        reason: 'the first interval must start the tick',
      );

      // Act: stop while the tick is still gated, then release the gate.
      scheduler.stop();
      gate.complete();
      await pumpEventQueue();

      // Act: advance far past what would have been the reschedule.
      await timePort.advance(const Duration(milliseconds: 1000));
      await pumpEventQueue();

      // Assert: the in-flight tick's completion must not reschedule —
      // stop() already made its generation stale.
      expect(tickCount, equals(1));
      expect(scheduler.isRunning, isFalse);
    });

    test('restart while running forks nothing', () async {
      // Arrange
      final timePort = InMemoryTimePort();
      var tickCount = 0;
      final scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () => const Duration(milliseconds: 100),
        tick: () async => tickCount++,
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
      );

      // Act: start twice in a row without stopping in between — both
      // calls schedule a delay, so two are briefly in flight.
      scheduler.start();
      scheduler.start();
      expect(timePort.pendingDelayCount, equals(2));

      await timePort.advance(const Duration(milliseconds: 100));
      await pumpEventQueue();

      // Assert: only the live generation's loop may tick. If the first
      // start()'s callback weren't stale, it would tick too — forking a
      // second concurrent loop (the H2 scheduler-forking hazard the
      // generation token exists to foreclose).
      expect(
        tickCount,
        equals(1),
        reason:
            'a restart-while-running must bump the generation so only one '
            'loop survives — the earlier start()\'s delay must be stale, '
            'not fork a second concurrent loop (H2 scheduler-forking hazard)',
      );

      scheduler.stop();
    });

    test('a tick error goes to onTickError and the loop continues', () async {
      // Arrange: a tick that always throws.
      final timePort = InMemoryTimePort();
      final tickErrors = <Object>[];
      var tickCount = 0;
      final scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () => const Duration(milliseconds: 100),
        tick: () async {
          tickCount++;
          throw StateError('boom');
        },
        onTickError: (error, stackTrace) => tickErrors.add(error),
        onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
      );

      // Act: let two intervals elapse.
      scheduler.start();
      await timePort.advance(const Duration(milliseconds: 100));
      await pumpEventQueue();
      await timePort.advance(const Duration(milliseconds: 100));
      await pumpEventQueue();

      // Assert: both ticks ran, both errors were reported, and the loop
      // is still alive — a tick error is contained, never fatal.
      expect(tickCount, equals(2));
      expect(tickErrors, hasLength(2));
      expect(scheduler.isRunning, isTrue);

      scheduler.stop();
    });

    test(
      'a scheduling error stops the loop and calls onSchedulingError',
      () async {
        // Arrange: a port whose next delay() call fails once.
        final timePort = FailingDelayTimePort();
        final schedulingErrors = <Object>[];
        var tickCount = 0;
        final scheduler = GenerationScheduler(
          timePort: timePort,
          nextDelay: () => const Duration(milliseconds: 100),
          tick: () async => tickCount++,
          onTickError: (error, stackTrace) => fail('unexpected: $error'),
          onSchedulingError: (error, stackTrace) => schedulingErrors.add(error),
        );

        // Act: start against the broken port.
        timePort.failNextDelay = true;
        scheduler.start();
        await pumpEventQueue();

        // Assert: the scheduling failure is reported once and the loop
        // stops itself so isRunning reflects reality.
        expect(schedulingErrors, hasLength(1));
        expect(scheduler.isRunning, isFalse);

        // Act: failNextDelay resets itself after firing, so the port is
        // healed — a later start() must run normally.
        scheduler.start();
        await timePort.inner.advance(const Duration(milliseconds: 100));
        await pumpEventQueue();

        // Assert: the healed loop ticks like nothing happened.
        expect(tickCount, equals(1));
        expect(schedulingErrors, hasLength(1));

        scheduler.stop();
      },
    );
  });
}
