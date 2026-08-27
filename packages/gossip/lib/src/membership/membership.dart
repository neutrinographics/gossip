/// The membership context: the SWIM peer model and the detector that
/// maintains it.
///
/// Membership imports nothing from `sync/` — it exercises no ACL
/// concession today; its only cross-context edge is `shared/`.
library;

// Aggregates
export 'domain/aggregates/peer_registry.dart';

// Entities
export 'domain/entities/peer.dart';
export 'domain/entities/peer_metrics.dart';

// Events (the sealed MembershipEvent family)
export 'domain/events/membership_events.dart';

// Value objects
export 'domain/value_objects/peer_status.dart';

// Messages (membership's published wire language)
export 'domain/messages/ack.dart';
export 'domain/messages/ping.dart';
export 'domain/messages/ping_req.dart';

// Interfaces
export 'domain/interfaces/peer_repository.dart';

// Application (use-case orchestrators)
export 'application/failure_detector.dart';
export 'application/membership_timing_snapshot.dart';
export 'application/peer_service.dart';

// Infrastructure
export 'infrastructure/in_memory_peer_repository.dart';
export 'infrastructure/membership_message_codec.dart';
