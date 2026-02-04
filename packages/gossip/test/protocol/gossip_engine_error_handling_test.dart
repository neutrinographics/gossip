import 'dart:typed_data';

import 'package:gossip/src/domain/errors/sync_error.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:gossip/src/protocol/values/stream_digest.dart';
import 'package:test/test.dart';

import 'failure_detector_test_harness.dart' show FailingSendMessagePort;
import 'gossip_engine_test_harness.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  group('Error handling', () {
    test('emits messageCorrupted error for malformed message bytes', () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);

      h.startListening();

      final garbageBytes = Uint8List.fromList([255, 0, 1, 2, 3]);
      await peer.port.send(h.localNode, garbageBytes);
      await h.flush();

      expect(h.errors, hasLength(1));
      expect(h.errors.first, isA<PeerSyncError>());
      final error = h.errors.first as PeerSyncError;
      expect(error.type, equals(SyncErrorType.messageCorrupted));
      expect(error.peer, equals(peer.id));

      h.stopListening();
    });

    test('emits peerUnreachable error when transport send fails', () async {
      final bus = InMemoryMessageBus();
      final localPort = InMemoryMessagePort(NodeId('local'), bus);
      final failingPort = FailingSendMessagePort(localPort);

      final h = GossipEngineTestHarness(messagePort: failingPort);
      h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);

      await h.engine.performGossipRound();
      await h.flush();

      expect(h.errors, hasLength(1));
      final error = h.errors.first as PeerSyncError;
      expect(error.type, equals(SyncErrorType.peerUnreachable));

      await h.dispose();
    });

    test('gossip round error recovery continues scheduling', () async {
      final bus = InMemoryMessageBus();
      final localPort = InMemoryMessagePort(NodeId('local'), bus);
      final failingPort = FailingSendMessagePort(localPort);

      final h = GossipEngineTestHarness(
        gossipInterval: const Duration(milliseconds: 200),
        messagePort: failingPort,
      );
      h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);

      h.engine.start();

      // First gossip interval fires → round runs and fails
      await h.timePort.advance(const Duration(milliseconds: 201));
      await h.flush();

      expect(h.errors, isNotEmpty);

      // Scheduling should continue — next round should be pending
      expect(h.engine.isRunning, isTrue);
      expect(h.timePort.pendingDelayCount, greaterThan(0));

      h.engine.stop();
    });
  });

  // ---------------------------------------------------------------------------
  // HLC updates
  // ---------------------------------------------------------------------------

  group('HLC updates', () {
    test('handleDeltaResponse updates HLC from received entries', () {
      final h = GossipEngineTestHarness(withHlcClock: true);
      h.createChannel('ch1', streamIds: ['s1']);

      final clockBefore = h.hlcClock!.current;

      // Receive entries with a high HLC timestamp
      final remoteHlc = Hlc(999999999, 0);
      final entry = LogEntry(
        author: NodeId('remote'),
        sequence: 1,
        timestamp: remoteHlc,
        payload: Uint8List.fromList([1]),
      );

      final response = DeltaResponse(
        sender: NodeId('remote'),
        channelId: ChannelId('ch1'),
        streamId: StreamId('s1'),
        entries: [entry],
      );

      h.engine.handleDeltaResponse(response);

      // HLC should have advanced past the remote timestamp
      final clockAfter = h.hlcClock!.current;
      expect(
        clockAfter.physicalMs,
        greaterThanOrEqualTo(remoteHlc.physicalMs),
        reason: 'HLC should advance to at least the remote timestamp',
      );
      expect(
        clockAfter.compareTo(clockBefore),
        greaterThan(0),
        reason: 'HLC should have advanced',
      );
    });

    test('handleDeltaResponse works without HLC clock', () {
      final h = GossipEngineTestHarness();
      h.createChannel('ch1', streamIds: ['s1']);

      final entry = LogEntry(
        author: NodeId('remote'),
        sequence: 1,
        timestamp: Hlc(1000, 0),
        payload: Uint8List.fromList([1]),
      );

      final response = DeltaResponse(
        sender: NodeId('remote'),
        channelId: ChannelId('ch1'),
        streamId: StreamId('s1'),
        entries: [entry],
      );

      // Should not crash when no HLC clock is configured
      h.engine.handleDeltaResponse(response);

      // Entries should still be merged
      expect(
        h.entryRepository.entryCount(ChannelId('ch1'), StreamId('s1')),
        equals(1),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Message metrics
  // ---------------------------------------------------------------------------

  group('Message metrics', () {
    test(
      'records received message metrics for incoming gossip messages',
      () async {
        final h = GossipEngineTestHarness();
        final peer = h.addPeer('peer1');
        h.createChannel('ch1', streamIds: ['s1']);

        h.startListening();

        final before = h.peerRegistry.getPeer(peer.id)!.metrics;
        expect(before.messagesReceived, equals(0));

        // Send a DigestRequest from peer
        final request = DigestRequest(
          sender: peer.id,
          digests: [
            ChannelDigest(
              channelId: ChannelId('ch1'),
              streams: [
                StreamDigest(
                  streamId: StreamId('s1'),
                  version: VersionVector.empty,
                ),
              ],
            ),
          ],
        );
        await peer.port.send(h.localNode, h.codec.encode(request));
        await h.flush();

        final after = h.peerRegistry.getPeer(peer.id)!.metrics;
        expect(after.messagesReceived, equals(1));
        expect(after.bytesReceived, greaterThan(0));

        h.stopListening();
      },
    );

    test('records sent message metrics when sending gossip messages', () async {
      final h = GossipEngineTestHarness();
      final peer = h.addPeer('peer1');
      h.createChannel('ch1', streamIds: ['s1']);

      final before = h.peerRegistry.getPeer(peer.id)!.metrics;
      expect(before.messagesSent, equals(0));

      // Need peer port registered to receive the message
      final (_, sub) = h.captureMessages(peer);

      await h.engine.performGossipRound();
      await h.flush();

      final after = h.peerRegistry.getPeer(peer.id)!.metrics;
      expect(after.messagesSent, greaterThanOrEqualTo(1));

      await sub.cancel();
    });
  });
}
