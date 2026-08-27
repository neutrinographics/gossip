import 'package:gossip/src/shared/domain/interfaces/time_port.dart';

/// A delay-based periodic loop implementing the generation-guarded
/// `_generation`/`_scheduleNext...` idiom shared by the gossip round loop
/// and the SWIM probe loop.
///
/// Uses [TimePort.delay] rather than [TimePort.schedulePeriodic] so the
/// interval between ticks can change every cycle (see [nextDelay]) —
/// necessary for adaptive pacing (RTT-derived gossip intervals, SWIM
/// backoff) that a fixed periodic timer can't express.
///
/// ## The forking hazard this forecloses
///
/// A naive `delay().then(tick).then(scheduleNext)` loop forks into two
/// concurrent loops if [stop] and [start] happen within one interval: the
/// pre-stop delay is still pending, so when it eventually fires it ticks
/// and reschedules right alongside the freshly started loop.
/// [_generation] closes it: every [start] and [stop] bumps it, and a
/// scheduled callback checks it against the current value before doing
/// anything. A callback from a run that has since stopped or restarted
/// finds its captured generation stale and quietly does nothing instead
/// of ticking or rescheduling — so at most one loop is ever live.
///
/// ## Failure policy
///
/// The two failure modes are handled asymmetrically, on purpose:
/// - A [tick] error is a single round's business logic failing — reported
///   via [onTickError] and otherwise ignored; the loop reschedules and
///   tries again next interval. One bad round must not kill dissemination.
/// - A scheduling error (the [TimePort.delay] future itself completing
///   with an error, e.g. a broken platform timer) means the mechanism the
///   loop depends on to run at all is broken. Continuing to retry it
///   silently would leave [isRunning] claiming a loop that will never tick
///   again — so the scheduler stops itself first and reports the failure
///   via [onSchedulingError], keeping [isRunning] truthful.
class GenerationScheduler {
  GenerationScheduler({
    required this.timePort,
    required this.nextDelay,
    required this.tick,
    required this.onTickError,
    required this.onSchedulingError,
  });

  final TimePort timePort;

  /// Computes the delay before the next tick, called fresh every cycle
  /// (never cached) so callers can adapt the interval — e.g. jitter,
  /// RTT-derived pacing, or backoff — from one tick to the next.
  final Duration Function() nextDelay;

  /// The unit of work run once per interval.
  final Future<void> Function() tick;

  /// Reports a [tick] failure. The loop continues; see the class doc for
  /// the failure policy.
  final void Function(Object error, StackTrace stackTrace) onTickError;

  /// Reports a scheduling failure. Called for both a live and a stale
  /// delay failure: on a live failure the loop has already stopped itself
  /// ([isRunning] is false); a stale failure — from a generation that
  /// [stop] or a fresh [start] has since superseded — leaves a live loop
  /// running. Consumers that need to distinguish the two should read
  /// [isRunning]; see the class doc for the failure policy.
  final void Function(Object error, StackTrace stackTrace) onSchedulingError;

  /// Identifies the current run. Bumped by every [start] and [stop] so a
  /// callback scheduled by a previous run can recognize itself as stale —
  /// see the class doc's forking hazard.
  int _generation = 0;
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  /// Starts the loop, scheduling the first tick after [nextDelay] elapses.
  ///
  /// Always bumps [_generation], even if already running: a restart never
  /// forks a second loop alongside the existing one because the previous
  /// generation's next scheduled callback — whenever it fires — finds
  /// itself stale and does nothing.
  void start() {
    _isRunning = true;
    _generation++; // any previously scheduled tick is now stale
    _scheduleNext(_generation);
  }

  /// Stops the loop. A tick already in flight is allowed to finish, but
  /// finding [_generation] stale, it will not reschedule.
  void stop() {
    _isRunning = false;
    _generation++;
  }

  void _scheduleNext(int generation) {
    if (!_isRunning || generation != _generation) return;
    timePort
        .delay(nextDelay())
        .then((_) async {
          if (!_isRunning || generation != _generation) return;
          try {
            await tick();
          } catch (error, stackTrace) {
            onTickError(error, stackTrace);
          }
          _scheduleNext(generation);
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (generation == _generation) {
            _isRunning = false;
            _generation++;
          }
          onSchedulingError(error, stackTrace);
        });
  }
}
