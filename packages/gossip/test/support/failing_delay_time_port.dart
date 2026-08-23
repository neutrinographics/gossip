import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/shared/domain/interfaces/time_port.dart';

/// A [TimePort] whose [delay] can be made to fail on demand.
///
/// Delegates to an [InMemoryTimePort] for normal operation. Set
/// [failNextDelay] to make the next [delay] call return a failed future,
/// simulating a broken platform timer.
class FailingDelayTimePort implements TimePort {
  final InMemoryTimePort inner = InMemoryTimePort();

  /// When true, the next [delay] call fails; resets to false after firing.
  bool failNextDelay = false;

  @override
  int get nowMs => inner.nowMs;

  @override
  TimerHandle schedulePeriodic(Duration interval, void Function() callback) =>
      inner.schedulePeriodic(interval, callback);

  @override
  Future<void> delay(Duration duration) {
    if (failNextDelay) {
      failNextDelay = false;
      return Future.error(StateError('simulated delay failure'));
    }
    return inner.delay(duration);
  }
}
