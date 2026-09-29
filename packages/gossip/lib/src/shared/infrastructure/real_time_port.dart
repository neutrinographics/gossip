import 'dart:async';
import 'package:gossip/src/shared/domain/interfaces/time_port.dart';

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
/// final timePort = RealTimePort();
/// final coordinator = await Coordinator.create(
///   localNodeRepository: InMemoryLocalNodeRepository(nodeId: nodeId),
///   timePort: timePort,
///   // ...
/// );
/// ```
class RealTimePort implements TimePort {
  /// Runs for the life of this port, so [monotonicMs] is elapsed time and not
  /// a calendar reading — the one clock a correction cannot touch.
  final Stopwatch _sinceCreation = Stopwatch()..start();

  @override
  int get nowMs => DateTime.now().millisecondsSinceEpoch;

  @override
  int get monotonicMs => _sinceCreation.elapsedMilliseconds;

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
