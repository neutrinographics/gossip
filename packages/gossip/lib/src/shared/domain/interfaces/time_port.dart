/// Handle for a scheduled timer, allowing cancellation.
///
/// Returned by [TimePort.schedulePeriodic] to allow individual timers
/// to be cancelled without affecting other scheduled timers.
abstract class TimerHandle {
  /// Cancels this timer.
  ///
  /// After cancellation, the callback will no longer be invoked.
  /// Safe to call multiple times.
  void cancel();
}

/// Port abstraction for time-related operations.
///
/// [TimePort] decouples the gossip library from platform-specific time
/// implementations, enabling:
/// - **Production**: Use real timers and wall-clock time ([RealTimePort])
/// - **Testing**: Use fake time ([InMemoryTimePort]) for deterministic tests
///
/// The library uses this port for:
/// - Scheduling periodic gossip rounds (adaptive: 2× median RTT, clamped 100 ms–5 s active, backed off to 30 s when idle)
/// - Scheduling SWIM probe rounds (adaptive: 3× the effective ping timeout, clamped 500 ms–30 s, paced toward the 30 s cap when quiet — see ADR-013 amendment)
/// - Getting current time for timestamps
/// - Creating timeouts for probe responses
///
/// ## Production Usage
///
/// ```dart
/// final coordinator = await Coordinator.create(
///   localNodeRepository: localNodeRepo,
///   channelRepository: channelRepo,
///   peerRepository: peerRepo,
///   entryRepository: entryRepo,
///   messagePort: myMessagePort,
///   timerPort: RealTimePort(),  // Use real time
/// );
/// ```
///
/// ## Testing Usage
///
/// ```dart
/// final timePort = InMemoryTimePort();
/// final coordinator = await Coordinator.create(
///   localNodeRepository: InMemoryLocalNodeRepository(),
///   // ... other params
///   timerPort: timePort,
/// );
///
/// await coordinator.start();
///
/// // Advance simulated time to trigger gossip rounds
/// await timePort.advance(Duration(seconds: 1));
/// ```
///
/// ## Multiple Timers
///
/// Multiple timers can be active concurrently. Each call to [schedulePeriodic]
/// returns an independent [TimerHandle]:
///
/// ```dart
/// final handle1 = port.schedulePeriodic(Duration(seconds: 1), gossip);
/// final handle2 = port.schedulePeriodic(Duration(seconds: 1), probe);
///
/// // Cancel individually
/// handle1.cancel();  // Stops gossip, probe continues
/// ```
///
/// See also:
/// - [RealTimePort] for production use
/// - [InMemoryTimePort] for testing
abstract class TimePort {
  /// Current time in milliseconds since epoch.
  ///
  /// In production, returns actual wall-clock time.
  /// In tests, returns simulated time controlled via [InMemoryTimePort.advance].
  int get nowMs;

  /// Schedules a callback to run periodically.
  ///
  /// Returns a [TimerHandle] that can be used to cancel this specific timer.
  /// Multiple timers can be scheduled concurrently.
  ///
  /// The first invocation happens after one [interval] elapses.
  TimerHandle schedulePeriodic(Duration interval, void Function() callback);

  /// Returns a future that completes after the given duration.
  ///
  /// In production, uses real time via [Future.delayed].
  /// In tests, completes when simulated time advances past the deadline.
  ///
  /// Use this for implementing timeouts instead of [Future.timeout] to enable
  /// deterministic testing.
  Future<void> delay(Duration duration);
}
