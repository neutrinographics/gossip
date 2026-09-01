/// The sync context: anti-entropy replication of the event log (channels,
/// streams, entries, retention, materialization).
///
/// Sync never names membership types directly outside its own
/// `infrastructure/` — see [MembershipPeerDirectory] below, the one
/// documented anti-corruption layer (ACL) concession. Every other file in
/// this context sees peers only through `PeerDirectory`/`SyncPartner`.
library;

import 'package:gossip/src/sync/infrastructure/membership_peer_directory.dart';

// Aggregates
export 'domain/aggregates/channel_aggregate.dart';
export 'domain/aggregates/stalled_range_registry.dart';

// Entities
export 'domain/entities/stalled_range.dart';

// Events (the sealed SyncEvent family)
export 'domain/events/sync_events.dart';

// Value objects
export 'domain/value_objects/channel_digest.dart';
export 'domain/value_objects/compaction_result.dart';
export 'domain/value_objects/stream_digest.dart';
export 'domain/value_objects/sync_partner.dart';

// Messages (sync's published wire language)
export 'domain/messages/delta_request.dart';
export 'domain/messages/delta_response.dart';
export 'domain/messages/digest_request.dart';
export 'domain/messages/digest_response.dart';

// Interfaces
export 'domain/interfaces/channel_repository.dart';
export 'domain/interfaces/entry_repository.dart';
export 'domain/interfaces/peer_directory.dart';
export 'domain/interfaces/retention_policy.dart';
export 'domain/interfaces/state_materializer.dart';

// Domain services
export 'domain/services/hlc_clock.dart';

// Application (use-case orchestrators)
export 'application/channel_service.dart';
export 'application/gossip_engine.dart';
export 'application/materialization/fold_cursor.dart';
export 'application/materialization/materialization_service.dart';
export 'application/materialization/materializer_state.dart';

// Infrastructure (incl. MembershipPeerDirectory, the sole membership-facing
// ACL, and SyncMessageCodec, sync's half of the dissolved central codec)
export 'infrastructure/caching_channel_repository.dart';
export 'infrastructure/in_memory_channel_repository.dart';
export 'infrastructure/in_memory_entry_repository.dart';
export 'infrastructure/membership_peer_directory.dart';
export 'infrastructure/sync_message_codec.dart';
