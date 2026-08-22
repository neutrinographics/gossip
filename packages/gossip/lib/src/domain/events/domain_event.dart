import 'package:gossip/src/domain/errors/sync_error.dart';

/// Base class for all domain events emitted by aggregates.
///
/// Domain events represent state changes that have already occurred within
/// the domain. Applications can observe these events to:
/// - Update read models or projections
/// - Trigger side effects (logging, notifications)
/// - Maintain event sourcing audit trails
/// - Synchronize with external systems
///
/// All events include an [occurredAt] timestamp indicating when the event
/// happened in domain time.
///
/// This base is intentionally NOT sealed: each bounded context defines its
/// own sealed event family that extends it (see [SyncEvent], containing
/// channel/stream/entry events, and [MembershipEvent], containing peer
/// registry events). Applications observing the shared `Stream<DomainEvent>`
/// are unaffected — every context-specific event still `is a` [DomainEvent].
abstract class DomainEvent {
  /// The timestamp when this event occurred.
  final DateTime occurredAt;

  const DomainEvent({required this.occurredAt});
}

// ─────────────────────────────────────────────────────────────
// Error Events
// ─────────────────────────────────────────────────────────────

/// Emitted when a synchronization error occurs.
///
/// Fired when: Operations encounter recoverable errors during sync
/// (e.g., malformed messages, validation failures). Applications can
/// observe these to log errors or implement retry policies.
final class SyncErrorOccurred extends DomainEvent {
  final SyncError error;

  const SyncErrorOccurred(this.error, {required super.occurredAt});
}
