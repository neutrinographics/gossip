import 'dart:async';
import 'time_port.dart';

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
/// final timerPort = InMemoryTimePort();
/// engine.start(); // Schedules periodic gossip
///
/// // Advance time by 1 second, triggering any scheduled callbacks
/// // and completing any delays that have elapsed
/// await timerPort.advance(Duration(seconds: 1));
///
/// // Legacy: tick() still works for just triggering periodic callbacks
/// timerPort.tick();
/// ```
///
/// ## Time Simulation
/// - [nowMs] returns the current simulated time
/// - [delay] creates a future that completes when simulated time advances
/// - [advance] moves time forward and resolves pending delays
/// - [tick] triggers periodic callbacks without advancing time (legacy)
class InMemoryTimePort implements TimePort {
  int _nextId = 0;
  int _nowMs = 0;
  final Map<int, void Function()> _callbacks = {};
  final List<_PendingDelay> _pendingDelays = [];

  @override
  int get nowMs => _nowMs;

  @override
  TimerHandle schedulePeriodic(Duration interval, void Function() callback) {
    final id = _nextId++;
    _callbacks[id] = callback;
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
    _callbacks.remove(id);
  }

  /// Advances simulated time by the given duration.
  ///
  /// This method:
  /// 1. Advances [nowMs] by the duration
  /// 2. Completes any pending [delay] futures whose deadlines have passed
  /// 3. Triggers all periodic callbacks (like [tick])
  ///
  /// Use this instead of [tick] when testing code that uses timeouts.
  ///
  /// ```dart
  /// // Advance 500ms - any delay(Duration(milliseconds: 500)) will complete
  /// await timerPort.advance(Duration(milliseconds: 500));
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

    // Trigger periodic callbacks
    tick();

    // Allow microtasks to run (important for async code to proceed)
    await Future.delayed(Duration.zero);
  }

  /// Manually triggers all scheduled periodic callbacks.
  ///
  /// Invokes all callbacks registered via [schedulePeriodic] that haven't
  /// been cancelled. Does not advance simulated time or complete delays.
  ///
  /// For most tests, prefer [advance] which also handles timeouts.
  /// Use [tick] only when you need to trigger callbacks without
  /// affecting simulated time.
  void tick() {
    // Copy to avoid concurrent modification if callbacks schedule/cancel
    final callbacks = List<void Function()>.from(_callbacks.values);
    for (final callback in callbacks) {
      callback();
    }
  }

  /// Returns the number of active periodic timers.
  int get activeTimerCount => _callbacks.length;

  /// Returns the number of pending delays waiting to complete.
  int get pendingDelayCount => _pendingDelays.length;
}
