/// The supersession state of one periodic loop: the [number] a scheduled
/// continuation compares itself against before doing anything, the gate
/// saying whether the loop is meant to be running at all, and — while a wait
/// is pending — the instant that wait ends ([waitEndsAtMs]), on whatever
/// timeline the holder keeps its waits on (the scheduler's is monotonic).
///
/// All three together, in one value, because the question a continuation asks
/// is one question — am I still the live run, and if I am asleep, is my wait
/// worth cutting short? — and an answer stitched from parts held separately
/// can be true of neither. Whether news should cut a pending wait short is a
/// decision about this loop's state, so the rule lives here, on the value,
/// not in the adapter that merely executes it.
///
/// A value, not a holder: the rule that moves it is `LoopGeneration`'s pure
/// functions, and where it lives between moves is the scheduler's business.
class Generation {
  const Generation({
    required this.number,
    required this.running,
    this.waitEndsAtMs,
  });

  /// Before any loop has run: the gate is closed, so nothing is live.
  static const Generation initial = Generation(number: 0, running: false);

  /// Identifies the current run; every start and every stop moves on from it.
  final int number;

  /// Whether the loop is meant to be running at all.
  final bool running;

  /// When the current wait ends, or null while none is pending — a tick in
  /// flight has nothing to cut short, and neither has a stopped loop.
  final int? waitEndsAtMs;

  @override
  bool operator ==(Object other) =>
      other is Generation &&
      other.number == number &&
      other.running == running &&
      other.waitEndsAtMs == waitEndsAtMs;

  @override
  int get hashCode => Object.hash(number, running, waitEndsAtMs);

  @override
  String toString() =>
      'Generation(number: $number, running: $running, '
      'waitEndsAtMs: $waitEndsAtMs)';
}
