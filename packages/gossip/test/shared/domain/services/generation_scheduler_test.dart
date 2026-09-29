import 'dart:async';

import 'package:gossip/src/shared/domain/interfaces/time_port.dart';
import 'package:gossip/src/shared/domain/services/generation_scheduler.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:test/test.dart';

import '../../../support/failing_delay_time_port.dart';

/// A wall clock that can be corrected while the waits, driven by the
/// delegate, keep their own time — what a device whose clock is set while a
/// long wait is pending looks like from inside the scheduler.
class _SkewedWallClockTimePort implements TimePort {
  _SkewedWallClockTimePort(this.inner);

  final InMemoryTimePort inner;

  /// Added to the wall-clock reading only; the timers are unmoved.
  int wallSkewMs = 0;

  @override
  int get nowMs => inner.nowMs + wallSkewMs;

  @override
  int get monotonicMs => inner.monotonicMs;

  @override
  TimerHandle schedulePeriodic(Duration interval, void Function() callback) =>
      inner.schedulePeriodic(interval, callback);

  @override
  Future<void> delay(Duration duration) => inner.delay(duration);
}

/// A clock whose reading can be followed by a pause — time passing between
/// the moment a caller read it and the moment it acts on that reading.
class _PausingTimePort implements TimePort {
  _PausingTimePort(this.inner);

  final InMemoryTimePort inner;

  /// Armed once: the next [monotonicMs] answers with the reading taken
  /// before this much simulated time passes.
  Duration? pauseAfterNextMonotonicRead;

  @override
  int get nowMs => inner.nowMs;

  @override
  int get monotonicMs {
    final reading = inner.monotonicMs;
    final pause = pauseAfterNextMonotonicRead;
    if (pause != null) {
      pauseAfterNextMonotonicRead = null;
      inner.advanceTimeOnly(pause);
    }
    return reading;
  }

  @override
  TimerHandle schedulePeriodic(Duration interval, void Function() callback) =>
      inner.schedulePeriodic(interval, callback);

  @override
  Future<void> delay(Duration duration) => inner.delay(duration);
}

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
      // second concurrent loop (the scheduler-forking hazard the
      // generation token exists to foreclose).
      expect(
        tickCount,
        equals(1),
        reason:
            'a restart-while-running must bump the generation so only one '
            'loop survives — the earlier start()\'s delay must be stale, '
            'not fork a second concurrent loop',
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

    test('the wait is on the clock before start returns', () {
      // Arrange
      final timePort = InMemoryTimePort();
      final scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () => const Duration(seconds: 30),
        tick: () async {},
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
      );

      // Act: no await — the wait must be recorded and taken in the same
      // synchronous run.
      scheduler.start();

      // Assert: were the delay taken a hop later, every recorded wait end
      // would sit earlier than the timer's by that hop, and a wake near the
      // end would decline a wait that still had time to run.
      expect(timePort.pendingDelayCount, equals(1));

      scheduler.stop();
    });

    test('a nextDelay of no time at all is a scheduling failure', () async {
      // Arrange: a loop that would wait nothing has no cadence; taken at its
      // word it would spin.
      final timePort = InMemoryTimePort();
      final schedulingErrors = <Object>[];
      var tickCount = 0;
      final scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () => Duration.zero,
        tick: () async => tickCount++,
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => schedulingErrors.add(error),
      );

      // Act
      scheduler.start();
      await timePort.advance(const Duration(seconds: 1));
      await pumpEventQueue();

      // Assert: reported once, the loop truthfully over, nothing armed.
      expect(schedulingErrors, hasLength(1));
      expect(scheduler.isRunning, isFalse);
      expect(tickCount, equals(0));
      expect(timePort.pendingDelayCount, equals(0));
    });

    test('a nextDelay that throws is a scheduling failure, not an '
        'exception out of start', () async {
      // Arrange
      final timePort = InMemoryTimePort();
      final schedulingErrors = <Object>[];
      final scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () => throw StateError('no interval'),
        tick: () async => fail('the loop never got a cadence'),
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => schedulingErrors.add(error),
      );

      // Act: reading the interval is part of the mechanism the loop runs on,
      // so its failure takes the mechanism's path, not the caller's.
      scheduler.start();
      await pumpEventQueue();

      // Assert
      expect(schedulingErrors, hasLength(1));
      expect(scheduler.isRunning, isFalse);
      expect(timePort.pendingDelayCount, equals(0));
    });
  });

  group('GenerationScheduler.wake', () {
    test(
      'wake cuts short a wait that would outlast a fresh interval',
      () async {
        // Arrange: a loop that has stretched to the idle ceiling.
        final timePort = InMemoryTimePort();
        var delay = const Duration(seconds: 30);
        var tickCount = 0;
        final scheduler = GenerationScheduler(
          timePort: timePort,
          nextDelay: () => delay,
          tick: () async {
            tickCount++;
            // Back to the idle stretch once the woken round has run, so no
            // later tick of the fresh chain can be mistaken for the superseded
            // wait firing.
            delay = const Duration(seconds: 30);
          },
          onTickError: (error, stackTrace) => fail('unexpected: $error'),
          onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
        );

        // Act: news resets the pace, then wakes the loop.
        scheduler.start();
        delay = const Duration(milliseconds: 250);
        scheduler.wake();

        // Assert: the superseded wait and the fresh one are genuinely in
        // flight together — the overlap the generation move has to answer.
        expect(timePort.pendingDelayCount, equals(2));

        await timePort.advance(const Duration(milliseconds: 249));
        await pumpEventQueue();
        expect(tickCount, equals(0));

        await timePort.advance(const Duration(milliseconds: 1));
        await pumpEventQueue();
        expect(
          tickCount,
          equals(1),
          reason: 'the round runs at the fresh interval, not the stretched one',
        );

        // Act: the pre-wake 30 s wait now comes due.
        await timePort.advance(const Duration(milliseconds: 29750));
        await pumpEventQueue();

        // Assert: it ticks nothing.
        expect(tickCount, equals(1));

        scheduler.stop();
      },
    );

    test(
      'wake leaves a wait already shorter than the fresh interval alone',
      () async {
        // Arrange: a loop already at the active cadence.
        final timePort = InMemoryTimePort();
        var delay = const Duration(milliseconds: 200);
        var tickCount = 0;
        final scheduler = GenerationScheduler(
          timePort: timePort,
          nextDelay: () => delay,
          tick: () async => tickCount++,
          onTickError: (error, stackTrace) => fail('unexpected: $error'),
          onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
        );

        // Act
        scheduler.start();
        delay = const Duration(milliseconds: 250);
        scheduler.wake();

        // Assert: nothing was superseded — one wait, still the original one,
        // so a busy room does not round on every merge.
        expect(timePort.pendingDelayCount, equals(1));

        await timePort.advance(const Duration(milliseconds: 199));
        await pumpEventQueue();
        expect(tickCount, equals(0));

        await timePort.advance(const Duration(milliseconds: 1));
        await pumpEventQueue();
        expect(tickCount, equals(1));

        scheduler.stop();
      },
    );

    test('wake does nothing while no loop is running', () async {
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

      // Act: before any start, and after the loop is over.
      scheduler.wake();
      expect(timePort.pendingDelayCount, equals(0));
      scheduler.start();
      scheduler.stop();
      scheduler.wake();

      await timePort.advance(const Duration(seconds: 10));
      await pumpEventQueue();

      // Assert
      expect(tickCount, equals(0));
      expect(scheduler.isRunning, isFalse);
    });

    test('wake during an in-flight tick leaves the loop to its own '
        'reschedule', () async {
      // Arrange: a tick gated so it can be held in flight.
      final timePort = InMemoryTimePort();
      final gate = Completer<void>();
      var delay = const Duration(milliseconds: 100);
      var tickCount = 0;
      final scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () => delay,
        tick: () async {
          tickCount++;
          await gate.future;
        },
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
      );

      // Act: the wait ends, the tick starts and parks on the gate.
      scheduler.start();
      await timePort.advance(const Duration(milliseconds: 100));
      await pumpEventQueue();
      expect(tickCount, equals(1));
      expect(timePort.pendingDelayCount, equals(0));

      // Act: news arrives mid-tick.
      delay = const Duration(milliseconds: 250);
      scheduler.wake();

      // Assert: no wait armed behind the tick's back — its own reschedule
      // will read the fresh interval anyway.
      expect(timePort.pendingDelayCount, equals(0));

      gate.complete();
      await pumpEventQueue();
      expect(timePort.pendingDelayCount, equals(1));

      await timePort.advance(const Duration(milliseconds: 249));
      await pumpEventQueue();
      expect(tickCount, equals(1));

      await timePort.advance(const Duration(milliseconds: 1));
      await pumpEventQueue();
      expect(
        tickCount,
        equals(2),
        reason:
            'exactly one more tick, at the fresh interval after the '
            'in-flight one ended',
      );

      scheduler.stop();
    });

    test('wake asks for no interval while no wait is pending', () async {
      // Arrange: a tick gated so the loop can be caught with nothing armed.
      final timePort = InMemoryTimePort();
      final gate = Completer<void>();
      var reads = 0;
      final scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () {
          reads++;
          return const Duration(milliseconds: 100);
        },
        tick: () async => gate.future,
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
      );

      // Act
      scheduler.start();
      await timePort.advance(const Duration(milliseconds: 100));
      await pumpEventQueue();
      expect(reads, equals(1));
      scheduler.wake();

      // Assert: with no wait pending there is nothing to compare a fresh
      // interval against, so none is asked for.
      expect(reads, equals(1));

      gate.complete();
      await pumpEventQueue();
      expect(
        reads,
        equals(2),
        reason: "the tick's own reschedule reads the interval",
      );

      scheduler.stop();
    });

    test('a stop landing inside wake leaves the loop stopped', () async {
      // Arrange: the interval is read after wake has taken its readings and
      // before the step that decides — the one place a stop can land inside
      // a wake.
      final timePort = InMemoryTimePort();
      var delay = const Duration(seconds: 30);
      var stopWhenAsked = false;
      var tickCount = 0;
      late final GenerationScheduler scheduler;
      scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () {
          if (stopWhenAsked) {
            stopWhenAsked = false;
            scheduler.stop();
          }
          return delay;
        },
        tick: () async => tickCount++,
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
      );

      // Act
      scheduler.start();
      delay = const Duration(milliseconds: 250);
      stopWhenAsked = true;
      scheduler.wake();

      // Assert: the loop ends stopped and nothing ticks.
      expect(scheduler.isRunning, isFalse);
      await timePort.advance(const Duration(seconds: 31));
      await pumpEventQueue();
      expect(tickCount, equals(0));
    });

    test('a wake arms the delay it decided with, not a second draw', () async {
      // Arrange: start draws 30 s, the wake's own reading draws 250 ms, and
      // any further draw — the one a wake must not make — draws 900 ms.
      final timePort = InMemoryTimePort();
      final draws = <Duration>[
        const Duration(seconds: 30),
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 900),
        const Duration(milliseconds: 900),
      ];
      var tickCount = 0;
      final scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () => draws.removeAt(0),
        tick: () async => tickCount++,
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
      );

      // Act
      scheduler.start();
      scheduler.wake();
      await timePort.advance(const Duration(milliseconds: 250));
      await pumpEventQueue();

      // Assert: the wait armed is the interval the rule compared against.
      expect(
        tickCount,
        equals(1),
        reason:
            'a second draw would arm a wait the decision was never made '
            'about',
      );

      scheduler.stop();
    });

    test('a wake that pauses between reading the clock and deciding never '
        'ends later than the wait it cut short', () async {
      // Arrange: a wait ending at 1 000 on the timer's own clock.
      final clock = InMemoryTimePort();
      final timePort = _PausingTimePort(clock);
      var delay = const Duration(milliseconds: 1000);
      var tickCount = 0;
      final scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () => delay,
        tick: () async => tickCount++,
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
      );
      scheduler.start();
      await clock.advance(const Duration(milliseconds: 100));
      await pumpEventQueue();

      // Act: the wake reads 100, is paused until 700, then decides with 500
      // in hand — from 100 the wait ending at 1 000 is worth cutting short.
      // Re-armed for its full 500 from 700 it would end at 1 200, later than
      // the very wait it judged too far away.
      delay = const Duration(milliseconds: 500);
      timePort.pauseAfterNextMonotonicRead = const Duration(milliseconds: 600);
      scheduler.wake();

      await clock.advance(const Duration(milliseconds: 300)); // to 1 000
      await pumpEventQueue();

      // Assert
      expect(
        tickCount,
        equals(1),
        reason:
            'the woken wait ends no later than the one it replaced, '
            'however old the reading it was decided on',
      );

      scheduler.stop();
    });

    test('a wall clock set forward during a wait does not stop a wake from '
        'cutting it short', () async {
      // Arrange
      final clock = InMemoryTimePort();
      final timePort = _SkewedWallClockTimePort(clock);
      var delay = const Duration(seconds: 30);
      var tickCount = 0;
      final scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () => delay,
        tick: () async => tickCount++,
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
      );
      scheduler.start(); // a 30 s wait, armed
      await clock.advance(const Duration(seconds: 1));
      await pumpEventQueue();

      // Act: the wall clock is set an hour ahead; the timer has 29 s to go.
      timePort.wallSkewMs = const Duration(hours: 1).inMilliseconds;
      delay = const Duration(milliseconds: 250);
      scheduler.wake();

      await clock.advance(const Duration(milliseconds: 250));
      await pumpEventQueue();

      // Assert
      expect(
        tickCount,
        equals(1),
        reason:
            "the wait is judged on the timer's own clock, which the "
            'correction did not move',
      );

      scheduler.stop();
    });

    test('a wake whose readings belong to a run since replaced does '
        'nothing', () async {
      // Arrange: the wake's interval read restarts the scheduler before
      // answering, with an interval shorter than the wait the new run arms —
      // a wake deciding on that reading would cut a wait short that its
      // readings were never about.
      final timePort = InMemoryTimePort();
      var reads = 0;
      var tickCount = 0;
      late final GenerationScheduler scheduler;
      scheduler = GenerationScheduler(
        timePort: timePort,
        nextDelay: () {
          reads++;
          switch (reads) {
            case 1:
              return const Duration(milliseconds: 1000); // the woken wait
            case 2:
              // The wake's own reading: the run it was taken for ends and
              // another takes its place (draw 3 is that run's wait).
              scheduler.stop();
              scheduler.start();
              return const Duration(milliseconds: 250);
            default:
              return const Duration(seconds: 30);
          }
        },
        tick: () async => tickCount++,
        onTickError: (error, stackTrace) => fail('unexpected: $error'),
        onSchedulingError: (error, stackTrace) => fail('unexpected: $error'),
      );

      // Act
      scheduler.start();
      await timePort.advance(const Duration(milliseconds: 100));
      await pumpEventQueue();
      scheduler.wake();

      await timePort.advance(const Duration(milliseconds: 250));
      await pumpEventQueue();

      // Assert: the replacement's wait is not cut short, and the wait the
      // readings were about is stale.
      expect(tickCount, equals(0));

      await timePort.advance(const Duration(seconds: 30));
      await pumpEventQueue();
      expect(
        tickCount,
        equals(1),
        reason: 'the replacement ticks when its own wait ends',
      );
      expect(scheduler.isRunning, isTrue);

      scheduler.stop();
    });

    test(
      'a nextDelay that throws inside wake stops the loop and reports',
      () async {
        // Arrange
        final timePort = InMemoryTimePort();
        final schedulingErrors = <Object>[];
        var broken = false;
        var tickCount = 0;
        final scheduler = GenerationScheduler(
          timePort: timePort,
          nextDelay: () {
            if (broken) throw StateError('no interval');
            return const Duration(seconds: 30);
          },
          tick: () async => tickCount++,
          onTickError: (error, stackTrace) => fail('unexpected: $error'),
          onSchedulingError: (error, stackTrace) => schedulingErrors.add(error),
        );

        // Act
        scheduler.start();
        broken = true;
        scheduler.wake();
        await timePort.advance(const Duration(seconds: 31));
        await pumpEventQueue();

        // Assert: the failure belongs to the generation that was woken, so
        // that generation is over and isRunning says so.
        expect(schedulingErrors, hasLength(1));
        expect(scheduler.isRunning, isFalse);
        expect(tickCount, equals(0));
      },
    );
  });
}
