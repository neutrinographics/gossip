import 'dart:async';
import 'time_port.dart';

/// Real timer handle wrapping a Dart [Timer].
class _RealTimerHandle implements TimerHandle {
  final Timer _timer;

  _RealTimerHandle(this._timer);

  @override
  void cancel() {
    _timer.cancel();
  }
}

/// Production implementation of [TimePort] using real wall-clock time.
///
/// Uses Dart's [Timer] for periodic scheduling and [DateTime.now] for
/// current time. Suitable for production use.
///
/// ## Usage
/// ```dart
/// final timerPort = RealTimePort();
/// final coordinator = await Coordinator.create(
///   localNode: nodeId,
///   timerPort: timerPort,
///   // ...
/// );
/// ```
class RealTimePort implements TimePort {
  @override
  int get nowMs => DateTime.now().millisecondsSinceEpoch;

  @override
  TimerHandle schedulePeriodic(Duration interval, void Function() callback) {
    final timer = Timer.periodic(interval, (_) => callback());
    return _RealTimerHandle(timer);
  }

  @override
  Future<void> delay(Duration duration) {
    return Future.delayed(duration);
  }
}
