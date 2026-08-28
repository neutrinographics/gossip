// Exercises GossipEngine + FailureDetector cross-cutting metrics; lives
// here (not under membership/) because the sync engine's test harness is
// what drives both collaborators.
import 'dart:typed_data';

import 'package:gossip/src/shared/domain/value_objects/log_level.dart';
import 'package:gossip/src/membership/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_message_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:gossip/src/sync/domain/messages/digest_response.dart';
import 'package:gossip/src/membership/domain/messages/ping.dart';
import 'package:gossip/src/membership/infrastructure/membership_message_codec.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';
import 'package:test/test.dart';

import '../../support/coordinator_builder.dart';
import '../../support/pump.dart';
import 'gossip_engine_test_harness.dart';

/// LocalNodeRepository whose clock-state persistence fails.
class _FailingClockRepository extends InMemoryLocalNodeRepository {
  _FailingClockRepository({required super.nodeId});

  @override
  Future<void> saveClockState(Hlc state) async {
    throw StateError('disk full');
  }
}

void main() {
  final codec = MembershipMessageCodec();

  group('single metrics recording point', () {
    test(
      'an incoming message is counted once, not once per listener',
      () async {
        final localNode = NodeId('local');
        final peerId = NodeId('peer1');
        final bus = InMemoryMessageBus();
        final coordinator = await createTestCoordinator(
          bus: bus,
          timePort: InMemoryTimePort(),
        );
        await coordinator.addPeer(peerId);
        await coordinator.start();

        // One SWIM ping from the peer. Both the gossip engine and the
        // failure detector subscribe to the same incoming stream.
        final peerPort = InMemoryMessagePort(peerId, bus);
        await peerPort.send(
          localNode,
          codec.encode(Ping(sender: peerId, sequence: 1)),
        );
        final registry = coordinator.failureDetectorForTesting!.peerRegistry;
        await pumpUntil(
          () => (registry.getPeer(peerId)?.metrics.messagesReceived ?? 0) > 0,
          describe: 'the incoming Ping being recorded as a received message',
        );

        expect(
          registry.getPeer(peerId)!.metrics.messagesReceived,
          equals(1),
          reason:
              'both engines recording the same message doubles every rate '
              'metric an application might throttle on',
        );

        await peerPort.close();
      },
    );
  });

  group('clock persistence failures surface', () {
    test('a failing saveClockState is emitted via ErrorCallback, not '
        'dropped as an unhandled future', () async {
      final localNode = NodeId('local');
      final registry = PeerRegistry(localNode: localNode);
      final errors = <SyncError>[];
      final timePort = InMemoryTimePort();
      final engine = GossipEngineTestHarness.buildEngine(
        localNode: localNode,
        peerRegistry: registry,
        timePort: timePort,
        localNodeRepository: _FailingClockRepository(nodeId: localNode),
        onError: errors.add,
        withHlcClock: true,
      );
      final channelId = ChannelId('ch1');
      final streamId = StreamId('s1');
      GossipEngineTestHarness.registerChannel(engine, channelId, [streamId]);

      await engine.handleDeltaResponse(
        DeltaResponse(
          sender: NodeId('peer1'),
          channelId: channelId,
          streamId: streamId,
          entries: [
            LogEntry(
              author: NodeId('peer1'),
              sequence: 1,
              timestamp: Hlc(1000, 0),
              payload: Uint8List.fromList([1]),
            ),
          ],
        ),
      );
      await pumpUntil(
        () => errors.isNotEmpty,
        describe: 'the saveClockState failure surfacing via ErrorCallback',
      );

      expect(
        errors.first,
        isA<StorageSyncError>()
            .having((e) => e.type, 'type', SyncErrorType.storageFailure)
            .having(
              (e) => e.message,
              'message',
              contains('Failed to persist HLC clock state'),
            ),
        reason: 'a storage failure must be logged or emitted, never silent',
      );
    });
  });

  group('locally-missing streams are logged, not silently skipped', () {
    test('a digest for an unknown stream produces a log line', () async {
      final localNode = NodeId('local');
      final registry = PeerRegistry(localNode: localNode);
      final logs = <String>[];
      final engine = GossipEngineTestHarness.buildEngine(
        localNode: localNode,
        peerRegistry: registry,
        timePort: InMemoryTimePort(),
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: localNode),
        onLog: (LogLevel level, String message, [Object? e, StackTrace? st]) {
          logs.add(message);
        },
      );
      final channelId = ChannelId('ch1');
      // Channel exists but WITHOUT the advertised stream.
      GossipEngineTestHarness.registerChannel(engine, channelId, const []);

      await engine.handleDigestResponse(
        DigestResponse(
          sender: NodeId('peer1'),
          digests: [
            ChannelDigest(
              channelId: channelId,
              streams: [
                StreamDigest(
                  streamId: StreamId('remote-only-stream'),
                  version: VersionVector({NodeId('peer1'): 3}),
                ),
              ],
            ),
          ],
        ),
      );

      expect(
        logs.any((m) => m.contains('remote-only-stream')),
        isTrue,
        reason:
            'a peer\'s stream being invisible here forever needs at least '
            'a trace log — otherwise it is undiagnosable in the field',
      );
    });
  });
}
