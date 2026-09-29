import 'package:gossip/src/shared/domain/interfaces/time_port.dart';
import 'package:gossip/src/shared/domain/services/loop_generation.dart';
import 'package:gossip/src/shared/domain/value_objects/generation.dart';

/// A delay-based periodic loop implementing the generation-guarded
/// `_scheduleNext...` idiom shared by the gossip round loop, the probe loop,
/// and the coordinator's auto-compaction loop.
///
/// Uses [TimePort.delay] rather than [TimePort.schedulePeriodic] so the
/// interval between ticks can change every cycle (see [nextDelay]) —
/// necessary for adaptive pacing (RTT-derived gossip intervals, probe
/// backoff) that a fixed periodic timer can't express.
///
/// ## The forking hazard this forecloses
///
/// A naive `delay().then(tick).then(scheduleNext)` loop forks into two
/// concurrent loops if [stop] and [start] happen within one interval: the
/// pre-stop delay is still pending, so when it eventually fires it ticks
/// and reschedules right alongside the freshly started loop.
/// [Generation] closes it: every [start] and [stop] moves to a new one, and a
/// scheduled callback checks the one it captured before doing anything. A
/// callback from a run that has since stopped or restarted finds its captured
/// generation stale and quietly does nothing instead of ticking or
/// rescheduling — so at most one loop is ever live.
///
/// ## Waking a sleeping loop
///
/// Adaptive pacing consults [nextDelay] only when the next wait is armed, so
/// a wait armed at a stretched idle interval sleeps through news that has
/// since reset the pace. [wake] answers that: a pending wait that would
/// outlast a fresh [nextDelay] is superseded and a fresh one armed in its
/// place. Whether that is worth doing is a rule about the loop's state, not
/// about timers, so it lives on [Generation] (see [LoopGeneration.wake]) and
/// this class only executes the answer. The bounds do not move: a woken wait
/// is a [nextDelay] like any other, so a wake cannot round faster than the
/// pacing already allows.
///
/// ## Failure policy
///
/// The failure modes are handled asymmetrically, on purpose:
/// - A [tick] error is a single round's business logic failing — reported
///   via [onTickError] and otherwise ignored; the loop reschedules and
///   tries again next interval. One bad round must not kill dissemination.
/// - A scheduling error (the [TimePort.delay] future itself completing
///   with an error, e.g. a broken platform timer) means the mechanism the
///   loop depends on to run at all is broken. Continuing to retry it
///   silently would leave [isRunning] claiming a loop that will never tick
///   again — so the scheduler stops itself first and reports the failure
///   via [onSchedulingError], keeping [isRunning] truthful.
/// - A [nextDelay] that throws, or answers no time at all, is a scheduling
///   error too, wherever it is read (a start, a reschedule, a wake), and
///   takes that same path: a loop that would wait nothing has no cadence,
///   and taken at its word it would spin.
///
/// ## Known limit
///
/// A [wake] acts on the wait this scheduler has recorded, and between
/// reading a fresh interval and recording the wait there is none to find.
/// News landing exactly there is a no-op, and that wait — chosen before the
/// news — is slept in full: one stale interval, once. What keeps the window
/// to that is recording the wait and taking it in the same synchronous run,
/// which is also what keeps every recorded end the timer's own.
class GenerationScheduler {
  GenerationScheduler({
    required this.timePort,
    required this.nextDelay,
    required this.tick,
    required this.onTickError,
    required this.onSchedulingError,
  });

  /// The shortest wait a bounded re-arm may end up with: a wake must never
  /// run the tick inline, inside whoever happened to have the news.
  static const Duration _shortestWait = Duration(milliseconds: 1);

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
  /// failure: on a live failure the loop has already stopped itself
  /// ([isRunning] is false); a stale failure — from a generation that
  /// [stop] or a fresh [start] has since superseded — leaves a live loop
  /// running. Consumers that need to distinguish the two should read
  /// [isRunning]; see the class doc for the failure policy.
  final void Function(Object error, StackTrace stackTrace) onSchedulingError;

  /// Everything about this loop that outlives a call, in one value, moved
  /// only by [LoopGeneration]'s pure functions — see the class doc's forking
  /// hazard for what the generation is for.
  Generation _state = Generation.initial;

  bool get isRunning => _state.running;

  /// Starts the loop, scheduling the first tick after [nextDelay] elapses.
  ///
  /// Always moves to a new generation, even if already running: a restart
  /// never forks a second loop alongside the existing one because the
  /// previous generation's next scheduled callback — whenever it fires —
  /// finds itself stale and does nothing.
  void start() {
    final started = LoopGeneration.start(_state);
    _state = started.state;
    _scheduleNext(started.number);
  }

  /// Stops the loop. A tick already in flight is allowed to finish, but
  /// finding its generation stale, it will not reschedule.
  void stop() {
    _state = LoopGeneration.stop(_state);
  }

  /// News arrived: if the loop is asleep on a wait that would outlast a fresh
  /// [nextDelay], that wait is superseded and one of the fresh interval armed
  /// in its place — so the next round comes within the interval the news
  /// deserves, wherever the pacing had drifted to. In every other case this
  /// does nothing: see [LoopGeneration.wake] for which cases those are and
  /// why each is left alone.
  void wake() {
    final generation = _state.number;
    final waitEndsAtMs = _state.waitEndsAtMs;
    // No wait pending means nothing to compare a fresh interval against, so
    // none is asked for: a tick in flight reads one when it reschedules, and
    // a stopped loop never again.
    if (!_state.running || waitEndsAtMs == null) return;
    final fresh = _readDelay(generation);
    if (fresh == null) return;
    final nowMs = timePort.monotonicMs;
    // The readings were about one wait of one run. A stop and a start in
    // between — [nextDelay] is the caller's own code — make them about
    // nothing, the same test a stale continuation fails; so does that wait
    // ending and the tick arming the next under the same run, since a
    // reading taken for a wait that is over decides nothing about the one
    // that followed it.
    if (_state.number != generation || _state.waitEndsAtMs != waitEndsAtMs) {
      return;
    }
    final woken = LoopGeneration.wake(
      _state,
      nowMs: nowMs,
      freshDelayMs: fresh.inMilliseconds,
    );
    _state = woken.state;
    final cutShortAtMs = woken.cutShortAtMs;
    if (cutShortAtMs == null) return;
    // Armed with the very interval the rule compared against — a second draw
    // would arm a wait no decision was ever made about — and never ending
    // later than the wait it cut short.
    _scheduleNext(
      woken.state.number,
      decided: fresh,
      noLaterThanMs: cutShortAtMs,
    );
  }

  /// The loop's fresh interval, or null after treating a failure to read it
  /// as the scheduling failure it is: the generation the reading was for is
  /// expired first, so the loop reads as over, and only then is the failure
  /// reported — the same order a failing wait takes, so [isRunning] never
  /// says "running" about a loop with nothing armed. Expiring [generation]
  /// rather than whatever is current means a failure belonging to a run
  /// already superseded cannot stop the run that replaced it.
  Duration? _readDelay(int generation) {
    try {
      final delay = nextDelay();
      if (delay <= Duration.zero) {
        throw StateError("a loop's next delay must be positive, was $delay");
      }
      return delay;
    } catch (error, stackTrace) {
      _state = LoopGeneration.expire(_state, generation);
      onSchedulingError(error, stackTrace);
      return null;
    }
  }

  /// Arms the next wait for the run holding [generation].
  ///
  /// [decided] is an interval already read and already judged — a wake's —
  /// so the wait armed is the one the decision was made about. [noLaterThanMs]
  /// is the end of a wait being cut short, which the fresh one may not
  /// outlast however long the decision took to act on.
  void _scheduleNext(int generation, {Duration? decided, int? noLaterThanMs}) {
    if (!LoopGeneration.isLive(_state, generation)) return;
    final interval = decided ?? _readDelay(generation);
    if (interval == null) return;
    // Reading the interval runs the caller's own code, which may have stopped
    // or restarted the loop: there is nothing to arm for a run already over.
    if (!LoopGeneration.isLive(_state, generation)) return;
    // One clock reading for both the bound and the recorded end, so the wait
    // this loop believes in is the wait it takes.
    final nowMs = timePort.monotonicMs;
    final delay = noLaterThanMs == null
        ? interval
        : _atMost(interval, Duration(milliseconds: noLaterThanMs - nowMs));
    // Recorded before it is taken, and in the same synchronous run: a wake
    // arriving during this wait knows what it would be cutting short, and
    // knows it on the timeline the wait itself is on.
    _state = LoopGeneration.arm(_state, endsAtMs: nowMs + delay.inMilliseconds);
    timePort
        .delay(delay)
        .then((_) async {
          if (!LoopGeneration.isLive(_state, generation)) return;
          // Whether this run may tick and the end of its wait are one step:
          // answered apart, a wake could arm a fresh wait in between, behind
          // the back of a tick that is about to reschedule anyway.
          _state = LoopGeneration.ticking(_state);
          try {
            await tick();
          } catch (error, stackTrace) {
            onTickError(error, stackTrace);
          }
          _scheduleNext(generation);
        })
        .catchError((Object error, StackTrace stackTrace) {
          _state = LoopGeneration.expire(_state, generation);
          onSchedulingError(error, stackTrace);
        });
  }

  /// [interval], held to [bound] — and to a wait that is still a wait, since
  /// a bound already reached (or passed, on a reading taken earlier) would
  /// otherwise leave no time at all.
  static Duration _atMost(Duration interval, Duration bound) {
    final bounded = bound < interval ? bound : interval;
    return bounded < _shortestWait ? _shortestWait : bounded;
  }
}
