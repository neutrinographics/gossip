import 'dart:async';

import 'package:gossip/gossip.dart';

/// Builds a [Coordinator] backed by in-memory repositories, wired to the
/// supplied [messagePort]. Used by all integration tests in this package.
///
/// [config] overrides the coordinator defaults (e.g. a fixed short
/// gossip interval so adverse-link tests converge quickly).
Future<Coordinator> spawnCoordinator({
  required NodeId nodeId,
  required MessagePort messagePort,
  CoordinatorConfig? config,
}) async {
  return Coordinator.create(
    localNodeRepository: InMemoryLocalNodeRepository(nodeId: nodeId),
    channelRepository: InMemoryChannelRepository(),
    peerRepository: InMemoryPeerRepository(),
    entryRepository: InMemoryEntryRepository(),
    messagePort: messagePort,
    timePort: RealTimePort(),
    config: config,
  );
}

/// Polls [predicate] every [interval] until it returns true or [timeout]
/// elapses. Throws [TimeoutException] if the deadline is missed.
Future<void> waitFor(
  Future<bool> Function() predicate, {
  Duration interval = const Duration(milliseconds: 50),
  Duration timeout = const Duration(seconds: 5),
  String? what,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(interval);
  }
  throw TimeoutException(
    'waitFor(${what ?? 'condition'}) timed out after ${timeout.inSeconds}s',
  );
}
