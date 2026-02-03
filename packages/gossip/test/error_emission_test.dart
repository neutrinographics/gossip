import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:gossip/src/domain/errors/sync_error.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/events/domain_event.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:gossip/src/infrastructure/ports/message_port.dart';
import 'package:gossip/src/infrastructure/ports/time_port.dart';
import 'package:gossip/src/protocol/gossip_engine.dart';
import 'package:gossip/src/protocol/failure_detector.dart';
import 'package:gossip/src/application/services/channel_service.dart';
import 'package:gossip/src/application/services/peer_service.dart';

/// A mock MessagePort that throws on send for testing error handling.
class ThrowingMessagePort implements MessagePort {
  final Exception exceptionToThrow;
  final StreamController<IncomingMessage> _controller =
      StreamController<IncomingMessage>.broadcast();

  ThrowingMessagePort(this.exceptionToThrow);

  @override
  Future<void> send(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
    throw exceptionToThrow;
  }

  @override
  Stream<IncomingMessage> get incoming => _controller.stream;

  @override
  Future<void> close() async {
    await _controller.close();
  }

  @override
  int pendingSendCount(NodeId peer) => 0;

  @override
  int get totalPendingSendCount => 0;

  void injectMessage(IncomingMessage message) {
    _controller.add(message);
  }
}

/// A no-op timer handle for testing.
class _NoOpTimerHandle implements TimerHandle {
  @override
  void cancel() {}
}

/// A no-op TimePort for testing.
class NoOpTimePort implements TimePort {
  @override
  int get nowMs => 0;

  @override
  TimerHandle schedulePeriodic(Duration interval, void Function() callback) {
    return _NoOpTimerHandle();
  }

  @override
  Future<void> delay(Duration duration) => Future.value();
}

void main() {
  group('GossipEngine error emission', () {
    test('emits PeerSyncError when message send fails', () async {
      final localNode = NodeId('local');
      final remoteNode = NodeId('remote');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );
      peerRegistry.addPeer(remoteNode, occurredAt: DateTime.now());

      final entryRepo = InMemoryEntryRepository();
      final throwingPort = ThrowingMessagePort(Exception('Network error'));
      final timerPort = NoOpTimePort();

      final errors = <SyncError>[];
      final engine = GossipEngine(
        localNode: localNode,
        peerRegistry: peerRegistry,
        entryRepository: entryRepo,
        timePort: timerPort,
        messagePort: throwingPort,
        onError: (error) => errors.add(error),
      );

      // Perform a gossip round which should try to send and fail
      await engine.performGossipRound();

      expect(errors, hasLength(1));
      expect(errors.first, isA<PeerSyncError>());
      final peerError = errors.first as PeerSyncError;
      expect(peerError.type, equals(SyncErrorType.peerUnreachable));
      expect(peerError.peer, equals(remoteNode));
    });

    test('emits PeerSyncError on malformed incoming message', () async {
      final localNode = NodeId('local');
      final remoteNode = NodeId('remote');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );

      final entryRepo = InMemoryEntryRepository();
      final messagePort = ThrowingMessagePort(Exception('unused'));
      final timerPort = NoOpTimePort();

      final errors = <SyncError>[];
      final engine = GossipEngine(
        localNode: localNode,
        peerRegistry: peerRegistry,
        entryRepository: entryRepo,
        timePort: timerPort,
        messagePort: messagePort,
        onError: (error) => errors.add(error),
      );

      engine.startListening({});

      // Inject garbage bytes
      final garbage = Uint8List.fromList([0xFF, 0xFF, 0xFF]);
      messagePort.injectMessage(
        IncomingMessage(
          sender: remoteNode,
          bytes: garbage,
          receivedAt: DateTime.now(),
        ),
      );

      // Wait for async processing
      await Future.delayed(Duration(milliseconds: 10));

      expect(errors, hasLength(1));
      expect(errors.first, isA<PeerSyncError>());
      final peerError = errors.first as PeerSyncError;
      expect(peerError.type, equals(SyncErrorType.messageCorrupted));
      expect(peerError.peer, equals(remoteNode));
    });
  });

  group('FailureDetector error emission', () {
    test('emits PeerSyncError on malformed incoming message', () async {
      final localNode = NodeId('local');
      final remoteNode = NodeId('remote');
      final peerRegistry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );

      final messagePort = ThrowingMessagePort(Exception('unused'));
      final timerPort = NoOpTimePort();

      final errors = <SyncError>[];
      final detector = FailureDetector(
        localNode: localNode,
        peerRegistry: peerRegistry,
        timePort: timerPort,
        messagePort: messagePort,
        onError: (error) => errors.add(error),
      );

      detector.startListening();

      // Inject garbage bytes
      final garbage = Uint8List.fromList([0xFF, 0xFF, 0xFF]);
      messagePort.injectMessage(
        IncomingMessage(
          sender: remoteNode,
          bytes: garbage,
          receivedAt: DateTime.now(),
        ),
      );

      // Wait for async processing
      await Future.delayed(Duration(milliseconds: 10));

      expect(errors, hasLength(1));
      expect(errors.first, isA<PeerSyncError>());
      final peerError = errors.first as PeerSyncError;
      expect(peerError.type, equals(SyncErrorType.messageCorrupted));
    });
  });

  group('ChannelService error emission', () {
    test('emits StorageSyncError when repository is null', () async {
      final localNode = NodeId('local');
      final channelId = ChannelId('test-channel');

      final errors = <SyncError>[];
      final service = ChannelService(
        localNode: localNode,
        channelRepository: null, // No repository
        entryRepository: null,
        onError: (e) => errors.add(e),
      );

      await service.addMember(channelId, NodeId('member'));

      expect(errors, hasLength(1));
      expect(errors.first, isA<StorageSyncError>());
      final storageError = errors.first as StorageSyncError;
      expect(storageError.type, equals(SyncErrorType.storageFailure));
      expect(storageError.message, contains('no repository configured'));
    });

    test(
      'emits StorageSyncError when entry store is null for append',
      () async {
        final localNode = NodeId('local');
        final channelId = ChannelId('test-channel');
        final streamId = StreamId('test-stream');

        final errors = <SyncError>[];
        final service = ChannelService(
          localNode: localNode,
          channelRepository: null,
          entryRepository: null, // No entry store
          onError: (e) => errors.add(e),
        );

        await service.appendEntry(
          channelId,
          streamId,
          Uint8List.fromList([1, 2, 3]),
        );

        expect(errors, hasLength(1));
        expect(errors.first, isA<StorageSyncError>());
        final storageError = errors.first as StorageSyncError;
        expect(storageError.type, equals(SyncErrorType.storageFailure));
        expect(storageError.message, contains('no entry store configured'));
      },
    );

    test(
      'emits StorageSyncError when entry store is null for getEntries',
      () async {
        final localNode = NodeId('local');
        final channelId = ChannelId('test-channel');
        final streamId = StreamId('test-stream');

        final errors = <SyncError>[];
        final service = ChannelService(
          localNode: localNode,
          channelRepository: null,
          entryRepository: null, // No entry store
          onError: (e) => errors.add(e),
        );

        final entries = await service.getEntries(channelId, streamId);

        expect(entries, isEmpty); // Returns empty list
        expect(errors, hasLength(1));
        expect(errors.first, isA<StorageSyncError>());
      },
    );
  });

  group('PeerService error emission', () {
    test('emits StorageSyncError when repository is null', () async {
      final localNode = NodeId('local');
      final peerId = NodeId('peer');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );

      final errors = <SyncError>[];
      final service = PeerService(
        localNode: localNode,
        registry: registry,
        repository: null, // No repository
        onError: (e) => errors.add(e),
      );

      await service.addPeer(peerId);

      // Peer is added to registry, but persistence emits error
      expect(registry.getPeer(peerId), isNotNull);
      expect(errors, hasLength(1));
      expect(errors.first, isA<StorageSyncError>());
      final storageError = errors.first as StorageSyncError;
      expect(storageError.type, equals(SyncErrorType.storageFailure));
      expect(storageError.message, contains('no repository configured'));
    });
  });

  group('PeerRegistry observability events', () {
    test('emits PeerOperationSkipped for unknown peer', () {
      final localNode = NodeId('local');
      final unknownPeer = NodeId('unknown');
      final registry = PeerRegistry(
        localNode: localNode,
        initialIncarnation: 0,
      );

      registry.updatePeerStatus(
        unknownPeer,
        PeerStatus.suspected,
        occurredAt: DateTime.now(),
      );

      final events = registry.uncommittedEvents;
      expect(events, hasLength(1));
      expect(events.first, isA<PeerOperationSkipped>());
      final skippedEvent = events.first as PeerOperationSkipped;
      expect(skippedEvent.peerId, equals(unknownPeer));
      expect(skippedEvent.operation, equals('updatePeerStatus'));
    });

    test(
      'emits PeerOperationSkipped for updatePeerContact on unknown peer',
      () {
        final localNode = NodeId('local');
        final unknownPeer = NodeId('unknown');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );

        registry.updatePeerContact(
          unknownPeer,
          DateTime.now().millisecondsSinceEpoch,
        );

        final events = registry.uncommittedEvents;
        expect(events, hasLength(1));
        expect(events.first, isA<PeerOperationSkipped>());
        final skippedEvent = events.first as PeerOperationSkipped;
        expect(skippedEvent.operation, equals('updatePeerContact'));
      },
    );

    test(
      'emits PeerOperationSkipped for incrementFailedProbeCount on unknown peer',
      () {
        final localNode = NodeId('local');
        final unknownPeer = NodeId('unknown');
        final registry = PeerRegistry(
          localNode: localNode,
          initialIncarnation: 0,
        );

        registry.incrementFailedProbeCount(unknownPeer);

        final events = registry.uncommittedEvents;
        expect(events, hasLength(1));
        expect(events.first, isA<PeerOperationSkipped>());
        final skippedEvent = events.first as PeerOperationSkipped;
        expect(skippedEvent.operation, equals('incrementFailedProbeCount'));
      },
    );
  });
}
