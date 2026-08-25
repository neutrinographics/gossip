import 'package:test/test.dart';

/// Awaits event-loop turns until [condition] holds, then returns.
///
/// Replaces the suite's hand-rolled `for (…) await Future.delayed(Duration
/// .zero)` loops with unexplained magic counts (2/3/5/8/12…) — those pin
/// tests to the engine's current await depth and, worse, let an assertion
/// like `isEmpty` pass vacuously when the count runs out before the awaited
/// work has actually happened (CC5-25). A bounded poll instead fails loudly
/// — via [describe] — when the condition never becomes true, rather than
/// silently declaring victory.
///
/// [maxTurns] caps how many turns are awaited before giving up; the default
/// (64) is generous for anything short of a stuck test. For draining
/// whatever's already queued with no condition to wait for, use
/// `pumpEventQueue()` instead.
Future<void> pumpUntil(
  bool Function() condition, {
  int maxTurns = 64,
  String? describe,
}) async {
  for (var turn = 0; turn < maxTurns; turn++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  if (condition()) return;
  fail(
    'pumpUntil gave up after $maxTurns turns waiting for: '
    '${describe ?? '(no description given)'}',
  );
}
