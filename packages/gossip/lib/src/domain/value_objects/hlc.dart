/// Hybrid Logical Clock timestamp for causality tracking.
///
/// A [Hlc] combines physical wall-clock time with a logical counter to
/// create timestamps that are both human-readable and causally consistent.
/// This ensures unique, monotonically increasing timestamps even when
/// physical clocks are identical or move backwards.
///
/// HLCs enable:
/// - **Causality preservation**: Track happened-before relationships between events
/// - **Conflict resolution**: Deterministic ordering for concurrent updates
/// - **Bounded drift**: Tie timestamps to physical time for debugging
///
/// ## How HLC Works
///
/// When a local event occurs:
/// 1. Take max(local HLC physical, wall clock)
/// 2. If physical time unchanged, increment logical counter
/// 3. Otherwise, reset logical counter to 0
///
/// When receiving a remote event:
/// 1. Take max(local HLC physical, remote HLC physical, wall clock)
/// 2. Adjust logical counter based on which was larger
///
/// This ensures the HLC is always >= wall clock and monotonically increasing.
///
/// ## Structure
/// - **physicalMs**: 48-bit milliseconds since epoch (wall-clock time)
/// - **logical**: 16-bit counter for events within the same millisecond
///
/// ## Usage
///
/// HLCs are typically managed by the library internally. Applications
/// interact with them through [LogEntry.timestamp]:
///
/// ```dart
/// final entries = await stream.getAll();
/// for (final entry in entries) {
///   print('Time: ${entry.timestamp.physicalMs}, Counter: ${entry.timestamp.logical}');
/// }
///
/// // Entries are sorted by HLC
/// entries.sort(); // Uses LogEntry.compareTo which compares HLCs
/// ```
///
/// ## Invariants
/// - physicalMs must be non-negative (>= 0)
/// - logical must be non-negative (>= 0)
/// - logical must fit in 16 bits (0-65535)
///
/// Value objects are immutable and compared by value equality.
///
/// See also:
/// - [LogEntry] which contains HLC timestamps
/// - ADR-005 for the design rationale
class Hlc implements Comparable<Hlc> {
  /// Physical wall-clock time in milliseconds since epoch (48-bit).
  final int physicalMs;

  /// Logical counter for events within the same millisecond (16-bit).
  final int logical;

  /// Creates a [Hlc] with the given physical and logical components.
  ///
  /// Throws [ArgumentError] if invariants are violated.
  Hlc(int physicalMs, int logical)
    : physicalMs = physicalMs,
      logical = logical {
    if (physicalMs < 0) {
      throw ArgumentError.value(
        physicalMs,
        'physicalMs',
        'Physical time cannot be negative',
      );
    }
    if (logical < 0) {
      throw ArgumentError.value(
        logical,
        'logical',
        'Logical counter cannot be negative',
      );
    }
    if (logical > 65535) {
      throw ArgumentError.value(
        logical,
        'logical',
        'Logical counter must fit in 16 bits (0-65535)',
      );
    }
  }

  /// Private const constructor for zero constant.
  const Hlc._internal(this.physicalMs, this.logical);

  /// Zero timestamp representing the earliest possible time.
  static const zero = Hlc._internal(0, 0);

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.physicalMs == physicalMs &&
      other.logical == logical;

  @override
  int get hashCode => Object.hash(physicalMs, logical);

  @override
  int compareTo(Hlc other) {
    final physical = physicalMs.compareTo(other.physicalMs);
    if (physical != 0) return physical;
    return logical.compareTo(other.logical);
  }

  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <=(Hlc other) => compareTo(other) <= 0;
  bool operator >=(Hlc other) => compareTo(other) >= 0;

  /// Subtracts a duration from the physical time component.
  ///
  /// Returns a new [Hlc] with the logical counter reset to zero.
  /// Used for calculating time-based thresholds (e.g., retention policies).
  Hlc subtract(Duration d) => Hlc(physicalMs - d.inMilliseconds, 0);

  @override
  String toString() => 'Hlc($physicalMs:$logical)';
}
