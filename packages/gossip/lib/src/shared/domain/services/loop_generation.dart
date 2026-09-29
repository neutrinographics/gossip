import 'package:gossip/src/shared/domain/value_objects/generation.dart';

/// The supersession rule of a periodic loop, as pure functions over
/// [Generation]: every start and every stop moves to a new generation, so a
/// continuation that captured an older one finds itself stale and expires
/// instead of ticking. That is what keeps at most one loop live when a stop
/// and a start land inside a single interval — see `GenerationScheduler`, the
/// one caller, for the hazard itself.
///
/// [arm] and [ticking] track a running loop's current wait so [wake] can
/// decide, from the value alone, whether news should cut that wait short: a
/// sleeping loop can be told the situation changed without the adapter having
/// to reason about it.
///
/// Stateless by construction — every answer is a function of the value handed
/// in — which leaves where that value lives to the caller, and the rule
/// itself testable without a clock or a timer in sight. A namespace, never an
/// instance: there is nothing here to configure or to hold.
abstract final class LoopGeneration {
  /// Opens the gate; the answer carries the generation the new loop runs
  /// under, which its continuations compare themselves against.
  static ({Generation state, int number}) start(Generation g) {
    final opened = Generation(number: g.number + 1, running: true);
    return (state: opened, number: opened.number);
  }

  /// Closes the gate; a run already in flight finds its generation stale.
  static Generation stop(Generation g) =>
      Generation(number: g.number + 1, running: false);

  /// Whether a run holding [number] may proceed.
  static bool isLive(Generation g, int number) =>
      g.running && number == g.number;

  /// A run holding [number] found its own mechanism broken: close the gate,
  /// but only if [number] is still current — a stale failure must not stop
  /// the loop that superseded it.
  static Generation expire(Generation g, int number) =>
      number == g.number ? stop(g) : g;

  /// Records that the running loop's current wait ends at [endsAtMs], so a
  /// later [wake] can tell whether that wait is worth cutting short.
  ///
  /// Throws [StateError] if the gate is closed: a loop that is not running
  /// has no wait of its own, and one recorded against it would outlive it.
  static Generation arm(Generation g, {required int endsAtMs}) {
    if (!g.running) {
      throw StateError('cannot arm a wait on a loop that is not running');
    }
    return Generation(
      number: g.number,
      running: g.running,
      waitEndsAtMs: endsAtMs,
    );
  }

  /// The wait has ended and the loop is ticking: nothing is pending any more.
  static Generation ticking(Generation g) =>
      Generation(number: g.number, running: g.running);

  /// News arrived: if the loop is running a wait that would end later than a
  /// fresh delay measured from [nowMs], that wait is stale — the generation
  /// moves on, so the continuation it armed expires when it fires — and the
  /// answer names the instant that wait would have ended, for the caller to
  /// arm the fresh wait itself, ending no later than that. A reading that has
  /// aged by the time it is acted on must not turn a wake into a longer wait.
  ///
  /// In every other case — not running, no wait pending, or a pending wait
  /// already no later than the fresh horizon — the value is unchanged and
  /// nothing was cut short: a node at the active cadence is left alone, so a
  /// busy room does not round on every piece of news.
  static ({Generation state, int? cutShortAtMs}) wake(
    Generation g, {
    required int nowMs,
    required int freshDelayMs,
  }) {
    final endsAtMs = g.waitEndsAtMs;
    if (!g.running || endsAtMs == null || endsAtMs <= nowMs + freshDelayMs) {
      return (state: g, cutShortAtMs: null);
    }
    return (
      state: Generation(number: g.number + 1, running: g.running),
      cutShortAtMs: endsAtMs,
    );
  }
}
