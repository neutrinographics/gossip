import 'dart:async';
import 'package:gossip/src/shared/domain/interfaces/time_port.dart';

/// In-memory timer handle for testing.
class _InMemoryTimerHandle implements TimerHandle {
  final InMemoryTimePort _port;
  final int _id;

  _InMemoryTimerHandle(this._port, this._id);

  @override
  void cancel() {
    _port._cancelTimer(_id);
  }
}

/// Tracks a pending delay that should complete when time advances.
class _PendingDelay {
  final int completeAtMs;
  final Completer<void> completer;

  _PendingDelay(this.completeAtMs, this.completer);
}

/// Tracks a periodic timer's own interval and next firing boundary.
///
/// [nextFireAtMs] mirrors [TimePort.schedulePeriodic]'s contract ("the
/// first invocation happens after one interval elapses") and advances by
/// [intervalMs] each time it fires, so [InMemoryTimePort.advance] can fire
/// this timer exactly as many times as the elapsed simulated time crosses
/// interval boundaries — the same count a real [Timer.periodic] would
/// produce over that much wall-clock time.
class _PeriodicTimer {
  final int intervalMs;
  final void Function() callback;
  int nextFireAtMs;

  _PeriodicTimer(this.intervalMs, this.callback, this.nextFireAtMs);
}

/// In-memory implementation of [TimePort] for deterministic testing.
///
/// Instead of using wall-clock time, [InMemoryTimePort] maintains a
/// simulated clock that advances only when [advance] is called. This enables:
/// - **Deterministic tests**: No race conditions from real timers
/// - **Fast tests**: No waiting for actual time to elapse
/// - **Precise control**: Control exactly when timeouts expire
///
/// **Use only for testing.**
///
/// ## Usage in Tests
/// ```dart
/// final timePort = InMemoryTimePort();
/// engine.start(); // Schedules periodic gossip
///
/// // Advance time by 1 second, triggering any scheduled callbacks
/// // and completing any delays that have elapsed
/// await timePort.advance(Duration(seconds: 1));
/// ```
///
/// ## Time Simulation
/// - [nowMs] returns the current simulated time
/// - [delay] creates a future that completes when simulated time advances
/// - [advance] moves time forward, resolves pending delays, and fires each
///   periodic timer once per interval boundary it crosses
/// - [tick] deprecated; fires every periodic callback once, unconditionally,
///   without advancing time or respecting any timer's own interval
class InMemoryTimePort implements TimePort {
  int _nextId = 0;
  int _nowMs = 0;
  final Map<int, _PeriodicTimer> _timers = {};
  final List<_PendingDelay> _pendingDelays = [];

  @override
  int get nowMs => _nowMs;

  /// Schedules a periodic callback.
  ///
  /// [interval] must resolve to a positive whole millisecond count
  /// (`interval.inMilliseconds > 0`) — [advance] reaches each firing
  /// boundary by repeatedly adding [interval] to the timer's last fire
  /// time, which never reaches (or regresses infinitely away from) `_nowMs`
  /// for a zero, sub-millisecond (truncates to zero), or negative interval.
  /// Rather than hang there silently, the invalid interval is rejected
  /// here, at the point it's supplied.
  ///
  /// Throws [ArgumentError] if `interval.inMilliseconds <= 0`.
  @override
  TimerHandle schedulePeriodic(Duration interval, void Function() callback) {
    if (interval.inMilliseconds <= 0) {
      throw ArgumentError.value(
        interval,
        'interval',
        'must be a positive duration of at least 1ms (whole milliseconds) '
            '— advance() cannot make progress toward a non-positive '
            'interval boundary',
      );
    }
    final id = _nextId++;
    // First fire is one interval from now (matches RealTimePort's
    // Timer.periodic and TimePort.schedulePeriodic's documented contract).
    _timers[id] = _PeriodicTimer(
      interval.inMilliseconds,
      callback,
      _nowMs + interval.inMilliseconds,
    );
    return _InMemoryTimerHandle(this, id);
  }

  @override
  Future<void> delay(Duration duration) {
    final completeAtMs = _nowMs + duration.inMilliseconds;
    final completer = Completer<void>();
    _pendingDelays.add(_PendingDelay(completeAtMs, completer));
    return completer.future;
  }

  void _cancelTimer(int id) {
    _timers.remove(id);
  }

  /// Advances simulated time by the given duration.
  ///
  /// This method:
  /// 1. Advances [nowMs] by the duration
  /// 2. Completes any pending [delay] futures whose deadlines have passed
  /// 3. Fires every overdue periodic-timer boundary, one boundary per
  ///    firing, in GLOBAL deadline order across all live timers (ties break
  ///    by registration order) — never exhausting one timer's boundaries
  ///    before another is even considered. Advancing by exactly
  ///    `n × interval` fires an uncancelled timer `n` times total (never
  ///    once per [advance] call regardless of the timer's own interval),
  ///    matching what independently-firing real [Timer.periodic]s would
  ///    produce over that much wall-clock time. Sub-interval advances that
  ///    don't reach the next boundary fire zero times but still count
  ///    toward it. Each timer's boundary is advanced *before* its callback
  ///    runs, so a callback that throws still consumes that boundary —
  ///    [advance] propagates the exception, but the timer resumes at its
  ///    next boundary on a later call rather than retrying the same
  ///    overdue one forever.
  ///
  /// ```dart
  /// // Advance 500ms - any delay(Duration(milliseconds: 500)) will complete,
  /// // and a schedulePeriodic(Duration(milliseconds: 100), ...) timer fires 5 times.
  /// await timePort.advance(Duration(milliseconds: 500));
  /// ```
  Future<void> advance(Duration duration) async {
    _nowMs += duration.inMilliseconds;

    // Complete any delays that have elapsed
    final completed = <_PendingDelay>[];
    for (final pending in _pendingDelays) {
      if (pending.completeAtMs <= _nowMs && !pending.completer.isCompleted) {
        pending.completer.complete();
        completed.add(pending);
      }
    }
    _pendingDelays.removeWhere((p) => completed.contains(p));

    // Fire every overdue boundary in global deadline order — across ALL
    // live timers, not one timer exhausted fully before the next is even
    // considered. A callback that cancels another timer (or registers a
    // new one) must be able to preempt boundaries that haven't fired yet,
    // which a per-timer-first loop cannot honor. Re-scan _timers fresh on
    // every iteration (rather than snapshotting ids up front) precisely so
    // cancellations and new registrations made by a callback are visible
    // to the next selection.
    //
    // Ties (equal boundaries) fall to the earlier-registered timer: _timers
    // preserves insertion order, and the scan below keeps the first
    // minimum it finds (strict `<`, not `<=`).
    //
    // A newly-scheduled timer's first boundary is always strictly after
    // _nowMs (schedulePeriodic seeds it at `_nowMs + interval`), so a
    // timer registered by a callback mid-advance can never fire within
    // this same advance() call — no special-casing needed for that case.
    while (true) {
      int? dueId;
      int? dueAtMs;
      for (final entry in _timers.entries) {
        final nextFireAtMs = entry.value.nextFireAtMs;
        if (nextFireAtMs > _nowMs) continue;
        if (dueAtMs == null || nextFireAtMs < dueAtMs) {
          dueId = entry.key;
          dueAtMs = nextFireAtMs;
        }
      }
      if (dueId == null) break;

      final timer = _timers[dueId]!;
      // Advance the boundary BEFORE invoking the callback: if the
      // callback throws, the boundary must already be consumed —
      // otherwise this timer would stay stuck at the same overdue
      // boundary and re-fire it on every later advance() forever.
      timer.nextFireAtMs += timer.intervalMs;
      timer.callback();
    }

    // Allow microtasks to run (important for async code to proceed)
    await Future.delayed(Duration.zero);
  }

  /// Manually triggers all scheduled periodic callbacks exactly once each,
  /// unconditionally — ignoring each timer's own interval and the
  /// boundary bookkeeping [advance] maintains.
  ///
  /// Invokes all callbacks registered via [schedulePeriodic] that haven't
  /// been cancelled. Does not advance simulated time or complete delays.
  ///
  /// For most tests, prefer [advance] which also handles timeouts and
  /// respects each timer's configured interval.
  @Deprecated(
    'Use advance(); tick() only fires periodic callbacks without advancing time',
  )
  void tick() {
    // Copy to avoid concurrent modification if callbacks schedule/cancel
    final callbacks = List<void Function()>.from(
      _timers.values.map((t) => t.callback),
    );
    for (final callback in callbacks) {
      callback();
    }
  }

  /// Returns the number of active periodic timers.
  int get activeTimerCount => _timers.length;

  /// Returns the number of pending delays waiting to complete.
  int get pendingDelayCount => _pendingDelays.length;
}
