import 'package:gossip/src/shared/domain/interfaces/time_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';

// ignore: unused_import -- referenced only from a doc comment (`comment_references`).
import 'failing_delay_time_port.dart';

/// A [TimePort] whose [delay] fails on specific, pre-scripted call indices.
///
/// [FailingDelayTimePort] can only fail "the next call" — good enough for a
/// single scheduling failure, but the reactive-push wedge (CC5-7 residual)
/// needs a specific delay call, chosen from among several concurrently
/// in-flight ones (the round loop's and the debounce's), to fail while an
/// *earlier* call is still pending. That requires addressing calls by
/// position, not by a one-shot flag. [failDelayCalls] names the 1-indexed
/// call numbers (across the whole port's lifetime) that fail; every other
/// call — including calls before, between, and after the scripted ones —
/// delegates to [inner] and behaves exactly like a normal
/// [InMemoryTimePort]. Kept intentionally minimal: no other [TimePort]
/// behavior is customizable, so this doesn't grow into a second
/// [InMemoryTimePort].
class ScriptedDelayTimePort implements TimePort {
  ScriptedDelayTimePort({required this.failDelayCalls, InMemoryTimePort? inner})
    : inner = inner ?? InMemoryTimePort();

  /// The wrapped port every non-scripted call — and all non-[delay] members —
  /// delegates to.
  final InMemoryTimePort inner;

  /// 1-indexed [delay] call numbers that fail. Call N is the Nth invocation
  /// of [delay] on this port instance, in call order (not completion order).
  final Set<int> failDelayCalls;

  int _delayCallCount = 0;

  @override
  int get nowMs => inner.nowMs;

  @override
  TimerHandle schedulePeriodic(Duration interval, void Function() callback) =>
      inner.schedulePeriodic(interval, callback);

  @override
  Future<void> delay(Duration duration) {
    _delayCallCount++;
    if (failDelayCalls.contains(_delayCallCount)) {
      return Future.error(
        StateError('scripted delay failure (call #$_delayCallCount)'),
      );
    }
    return inner.delay(duration);
  }

  /// Advances the wrapped port's simulated clock — see
  /// [InMemoryTimePort.advance].
  Future<void> advance(Duration duration) => inner.advance(duration);
}
