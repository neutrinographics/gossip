/// The shared kernel: value objects, interfaces, and services with no
/// dependency on `sync/` or `membership/` — a true leaf module.
///
/// Every other module (`sync/`, `membership/`, `coordinator/`) may import
/// this barrel; nothing in here imports anything outside `shared/`.
library;

// Value objects
export 'domain/value_objects/channel_id.dart';
export 'domain/value_objects/hlc.dart';
export 'domain/value_objects/log_entry.dart';
export 'domain/value_objects/log_entry_id.dart';
export 'domain/value_objects/log_level.dart';
export 'domain/value_objects/node_id.dart';
export 'domain/value_objects/rtt_estimate.dart';
export 'domain/value_objects/stream_id.dart';
export 'domain/value_objects/version_vector.dart';
export 'domain/value_objects/wire_types.dart';

// Events (per-context event families extend DomainEvent from here)
export 'domain/events/domain_event.dart';

// Errors
export 'domain/errors/domain_exception.dart';
export 'domain/errors/sync_error.dart';

// Interfaces (ports every context/coordinator may implement or consume)
export 'domain/interfaces/local_node_repository.dart';
export 'domain/interfaces/message_codec.dart';
export 'domain/interfaces/message_port.dart';
export 'domain/interfaces/protocol_message.dart';
export 'domain/interfaces/time_port.dart';

// Services
export 'domain/services/generation_scheduler.dart';
export 'domain/services/jitter.dart';
export 'domain/services/keyed_task_chain.dart';
export 'domain/services/quiescence_pacer.dart';
export 'domain/services/rtt_tracker.dart';
export 'domain/services/time_source.dart';

// Infrastructure (in-memory + production adapters for the ports above)
export 'infrastructure/in_memory_local_node_repository.dart';
export 'infrastructure/in_memory_message_port.dart';
export 'infrastructure/in_memory_time_port.dart';
export 'infrastructure/real_time_port.dart';
