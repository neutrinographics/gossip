import 'package:gossip/src/coordinator/coordinator.dart';
import 'package:gossip/src/coordinator/coordinator_config.dart';
import 'package:gossip/src/membership/domain/interfaces/peer_repository.dart';
import 'package:gossip/src/membership/infrastructure/in_memory_peer_repository.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/interfaces/local_node_repository.dart';
import 'package:gossip/src/shared/domain/interfaces/time_port.dart';
import 'package:gossip/src/shared/domain/value_objects/log_level.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/sync/domain/interfaces/channel_repository.dart';
import 'package:gossip/src/sync/domain/interfaces/entry_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_channel_repository.dart';
import 'package:gossip/src/sync/infrastructure/in_memory_entry_repository.dart';
import 'package:test/test.dart';

// Keyed on the coordinator instance rather than a value the caller could
// plausibly reuse (e.g. a String id), and weak so a long-running suite
// never pins disposed coordinators in memory just because a test once
// asked for their errors.
final Expando<List<SyncError>> _recordedErrors = Expando<List<SyncError>>(
  'createTestCoordinator recorded errors',
);

/// Builds a [Coordinator] wired with in-memory infrastructure, collapsing the
/// three copy-pasted `createCoordinator()` helpers this suite had grown into
/// one call. Only [bus] and [timePort] opt the coordinator into network sync —
/// omitting both reproduces `Coordinator.create`'s own local-only default,
/// which most of the suite wants.
///
/// The four repository parameters exist for tests whose point is
/// repository identity rather than coordinator behavior: hold a reference
/// to assert on it after the coordinator mutates it, pre-seed it before
/// `create` runs to prove load-on-create behavior, or pass the same
/// instance into two sequential [createTestCoordinator] calls to prove
/// state survives a simulated restart. Each defaults to null, in which
/// case the builder constructs the same fresh in-memory instance it always
/// has — every existing call site keeps identical behavior. [nodeId] is
/// only used to build a fresh [InMemoryLocalNodeRepository]; supplying both
/// [nodeId] and [localNodeRepository] throws [ArgumentError], since the
/// repository's own resolved identity would silently win (mirrors
/// `Coordinator.create`, which reads identity from the repository, not a
/// separate argument) and a caller passing both likely believes [nodeId]
/// took effect. One sharp edge remains unenforced: combining
/// [localNodeRepository] with [bus] registers the message port under
/// `'local'` regardless of the repository's resolved identity. The existing
/// callers that combine them (`coordinator_test.dart`'s clock-state
/// restoration tests) all use a repository resolving to `'local'`, so the
/// edge is latent there, not exercised — a repository resolving to any
/// other identity would silently never receive traffic. Enforcing this
/// would break those callers, so it's left as a signpost: extend the
/// builder before writing a test that needs a non-`'local'` identity here.
///
/// This builder deliberately does *not* serve tests of
/// `Coordinator.create`'s own constructor contract — passing a `null`
/// repository to prove its validation, or omitting `peerRepository` to
/// prove the production `??= InMemoryPeerRepository()` default fires.
/// Those call `Coordinator.create` directly and always will: this builder
/// always passes every repository parameter explicitly, so it cannot
/// exercise "what happens when one is omitted or null" without silently
/// stopping to test what its name promises.
///
/// Registers `addTearDown(coordinator.dispose)` before returning, so
/// cleanup still runs when an assertion later in the test throws — a
/// trailing `await coordinator.dispose()` at the end of the test body does
/// not. Because [addTearDown] is `package:test`'s, this must be
/// called from inside a `test()` body or `setUp` — calling it elsewhere
/// throws.
///
/// When [onError] is omitted, emitted [SyncError]s are collected instead of
/// silently dropped; retrieve them with [recordedErrorsOf]. Passing
/// [onError] takes over that responsibility entirely — [recordedErrorsOf]
/// then has nothing to return and throws.
Future<Coordinator> createTestCoordinator({
  String? nodeId,
  InMemoryMessageBus? bus,
  TimePort? timePort,
  CoordinatorConfig? config,
  LogCallback? onLog,
  void Function(SyncError)? onError,
  bool start = false,
  LocalNodeRepository? localNodeRepository,
  ChannelRepository? channelRepository,
  PeerRepository? peerRepository,
  EntryRepository? entryRepository,
}) async {
  if (nodeId != null && localNodeRepository != null) {
    throw ArgumentError(
      'Pass either nodeId or localNodeRepository, not both: the builder '
      'ignores nodeId when a repository is supplied (the repository\'s own '
      'resolved identity wins, mirroring Coordinator.create).',
    );
  }
  final localNode = NodeId(nodeId ?? 'local');

  final coordinator = await Coordinator.create(
    localNodeRepository:
        localNodeRepository ?? InMemoryLocalNodeRepository(nodeId: localNode),
    channelRepository: channelRepository ?? InMemoryChannelRepository(),
    peerRepository: peerRepository ?? InMemoryPeerRepository(),
    entryRepository: entryRepository ?? InMemoryEntryRepository(),
    messagePort: bus == null ? null : InMemoryMessagePort(localNode, bus),
    timePort: timePort,
    config: config,
    onLog: onLog,
  );

  addTearDown(coordinator.dispose);

  if (onError != null) {
    coordinator.errors.listen(onError);
  } else {
    final recorded = <SyncError>[];
    _recordedErrors[coordinator] = recorded;
    coordinator.errors.listen(recorded.add);
  }

  if (start) {
    await coordinator.start();
  }

  return coordinator;
}

/// Errors recorded for a [coordinator] built by [createTestCoordinator]
/// without an explicit `onError` — the default sink for tests that only
/// want to assert *whether* an error occurred, not thread a callback
/// through construction to observe it.
///
/// Throws if [coordinator] wasn't built by [createTestCoordinator], or was
/// built with its own `onError` (which took over error handling, so there
/// is nothing recorded here to return).
List<SyncError> recordedErrorsOf(Coordinator coordinator) {
  final recorded = _recordedErrors[coordinator];
  if (recorded == null) {
    throw StateError(
      'recordedErrorsOf: no recorded errors for this coordinator — it was '
      'either not built by createTestCoordinator, or was built with an '
      'explicit onError callback (which took over error handling instead)',
    );
  }
  return recorded;
}
