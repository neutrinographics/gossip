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

  @override
  TimerHandle schedulePeriodic(Duration interval, void Function() callback) {
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
  /// 3. Fires each periodic timer once per interval boundary the advance
  ///    crosses — advancing by exactly `n × interval` fires that timer `n`
  ///    times (never once per [advance] call regardless of the timer's own
  ///    interval), matching what a real [Timer.periodic] would produce over
  ///    that much wall-clock time. Sub-interval advances that don't reach
  ///    the next boundary fire zero times but still count toward it.
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

    // Fire each periodic timer once per interval boundary crossed by this
    // advance. Snapshot the ids first: a callback may cancel its own timer
    // (or another's) or schedule a new one, and neither should disturb this
    // loop — a newly-scheduled timer's first boundary is always in the
    // future relative to _nowMs, so it can't fire within this same advance.
    for (final id in List<int>.from(_timers.keys)) {
      while (true) {
        final timer = _timers[id];
        if (timer == null || timer.nextFireAtMs > _nowMs) break;
        timer.callback();
        timer.nextFireAtMs += timer.intervalMs;
      }
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
