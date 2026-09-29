import 'package:gossip/src/shared/domain/services/loop_generation.dart';
import 'package:gossip/src/shared/domain/value_objects/generation.dart';
import 'package:test/test.dart';

/// The supersession rule `GenerationScheduler` relies on, isolated from the
/// timers that execute it: each case hands a [Generation] in and judges the
/// one that comes back, which is the whole of what the rule is — there is no
/// instance here to drive into a state first.
void main() {
  group('LoopGeneration', () {
    test('nothing is live before a start', () {
      expect(
        LoopGeneration.isLive(Generation.initial, Generation.initial.number),
        isFalse,
      );
    });

    test('start opens the gate and hands out a fresh generation each time', () {
      final first = LoopGeneration.start(Generation.initial);
      final second = LoopGeneration.start(first.state);

      expect(second.state.running, isTrue);
      expect(second.number, equals(first.number + 1));
      expect(
        LoopGeneration.isLive(second.state, first.number),
        isFalse,
        reason: 'a restart supersedes the earlier generation',
      );
      expect(LoopGeneration.isLive(second.state, second.number), isTrue);
    });

    test('stop closes the gate and supersedes the current generation', () {
      final started = LoopGeneration.start(Generation.initial);

      final stopped = LoopGeneration.stop(started.state);

      expect(stopped.running, isFalse);
      expect(LoopGeneration.isLive(stopped, started.number), isFalse);
      expect(
        LoopGeneration.start(stopped).number,
        equals(started.number + 2),
        reason: 'stop bumped once, start bumps again',
      );
    });

    test('expire closes the gate for the current generation only', () {
      final stale = LoopGeneration.start(Generation.initial);
      final live = LoopGeneration.start(stale.state);

      final afterStale = LoopGeneration.expire(live.state, stale.number);
      expect(
        afterStale.running,
        isTrue,
        reason: 'a stale failure must not stop the live loop',
      );
      expect(LoopGeneration.isLive(afterStale, live.number), isTrue);

      final afterLive = LoopGeneration.expire(afterStale, live.number);
      expect(afterLive.running, isFalse);
      expect(LoopGeneration.isLive(afterLive, live.number), isFalse);
    });

    test('every transition answers with a successor and leaves its input '
        'untouched', () {
      final given = LoopGeneration.start(Generation.initial).state;
      final armed = LoopGeneration.arm(given, endsAtMs: 30000);

      // A transition that changed the value it was handed instead of
      // answering with a successor would move the loop's state behind the
      // back of the field that holds it.
      expect(LoopGeneration.start(given).state, isNot(same(given)));
      expect(LoopGeneration.stop(given), isNot(same(given)));
      expect(LoopGeneration.expire(given, given.number), isNot(same(given)));
      expect(LoopGeneration.arm(given, endsAtMs: 1), isNot(same(given)));
      expect(LoopGeneration.ticking(armed), isNot(same(armed)));
      expect(
        LoopGeneration.wake(armed, nowMs: 0, freshDelayMs: 250).state,
        isNot(same(armed)),
      );
      expect(
        given,
        equals(Generation(number: given.number, running: true)),
        reason: 'the value handed in is the value it still is',
      );
      expect(armed.waitEndsAtMs, equals(30000));
    });

    test('arm records the wait and leaves number and gate alone', () {
      final running = LoopGeneration.start(Generation.initial).state;

      final armed = LoopGeneration.arm(running, endsAtMs: 30000);

      expect(armed.waitEndsAtMs, equals(30000));
      expect(armed.number, equals(running.number));
      expect(armed.running, equals(running.running));
    });

    test('arm requires the gate to be open', () {
      expect(
        () => LoopGeneration.arm(Generation.initial, endsAtMs: 30000),
        throwsA(isA<StateError>()),
      );
    });

    test('ticking clears the pending wait and leaves number and gate '
        'alone', () {
      final running = LoopGeneration.start(Generation.initial).state;
      final armed = LoopGeneration.arm(running, endsAtMs: 30000);

      final ticking = LoopGeneration.ticking(armed);

      expect(ticking.waitEndsAtMs, isNull);
      expect(ticking.number, equals(armed.number));
      expect(ticking.running, equals(armed.running));
    });

    test('wake supersedes a wait that would end well after a fresh '
        'delay', () {
      final running = LoopGeneration.start(Generation.initial).state;
      final armed = LoopGeneration.arm(running, endsAtMs: 30000);

      final woken = LoopGeneration.wake(armed, nowMs: 0, freshDelayMs: 250);

      expect(
        woken.cutShortAtMs,
        equals(30000),
        reason:
            'the superseded wait is named, so the fresh one can end no '
            'later than it',
      );
      expect(woken.state.number, equals(armed.number + 1));
      expect(woken.state.running, isTrue);
      expect(
        woken.state.waitEndsAtMs,
        isNull,
        reason: 'the adapter arms the new wait, not this transition',
      );
    });

    test('wake leaves a wait already shorter than the fresh delay alone', () {
      final running = LoopGeneration.start(Generation.initial).state;
      final armed = LoopGeneration.arm(running, endsAtMs: 200);

      final woken = LoopGeneration.wake(armed, nowMs: 0, freshDelayMs: 250);

      expect(woken.cutShortAtMs, isNull);
      expect(woken.state, equals(armed));
    });

    test('wake leaves a wait ending exactly at the fresh horizon alone', () {
      final running = LoopGeneration.start(Generation.initial).state;
      final armed = LoopGeneration.arm(running, endsAtMs: 250);

      final woken = LoopGeneration.wake(armed, nowMs: 0, freshDelayMs: 250);

      expect(
        woken.cutShortAtMs,
        isNull,
        reason: 'a wait ending exactly at the fresh horizon is no improvement',
      );
      expect(woken.state, equals(armed));
    });

    test('wake does nothing when no wait is pending', () {
      final running = LoopGeneration.start(Generation.initial).state;

      final woken = LoopGeneration.wake(running, nowMs: 0, freshDelayMs: 250);

      expect(woken.cutShortAtMs, isNull);
      expect(woken.state, equals(running));
    });

    test('wake does nothing when the gate is closed', () {
      final stopped = LoopGeneration.stop(
        LoopGeneration.start(Generation.initial).state,
      );

      final woken = LoopGeneration.wake(stopped, nowMs: 0, freshDelayMs: 250);

      expect(woken.cutShortAtMs, isNull);
      expect(woken.state, equals(stopped));
    });

    test('start, stop and expire clear a pending wait when they move the '
        'generation', () {
      final running = LoopGeneration.start(Generation.initial).state;
      final armed = LoopGeneration.arm(running, endsAtMs: 30000);

      expect(
        LoopGeneration.start(armed).state.waitEndsAtMs,
        isNull,
        reason: 'start',
      );
      expect(LoopGeneration.stop(armed).waitEndsAtMs, isNull, reason: 'stop');

      final live = LoopGeneration.start(armed).state;
      final armedLive = LoopGeneration.arm(live, endsAtMs: 30000);
      expect(
        LoopGeneration.expire(armedLive, live.number).waitEndsAtMs,
        isNull,
        reason: 'expire, current generation',
      );
    });
  });
}
