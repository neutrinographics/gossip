import 'package:test/test.dart';
import 'package:gossip/src/domain/errors/sync_error.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';

void main() {
  group('SyncError', () {
    final now = DateTime(2024, 1, 15, 12, 0, 0);
    final peerId = NodeId('peer-1');
    final channelId = ChannelId('channel-1');
    final streamId = StreamId('stream-1');

    group('PeerSyncError', () {
      test('contains peer, type, message, occurredAt', () {
        final error = PeerSyncError(
          peerId,
          SyncErrorType.peerTimeout,
          'Peer timed out',
          occurredAt: now,
        );

        expect(error.peer, equals(peerId));
        expect(error.type, equals(SyncErrorType.peerTimeout));
        expect(error.message, equals('Peer timed out'));
        expect(error.occurredAt, equals(now));
        expect(error.cause, isNull);
      });

      test('contains optional cause', () {
        final cause = Exception('Network error');
        final error = PeerSyncError(
          peerId,
          SyncErrorType.peerUnreachable,
          'Cannot reach peer',
          occurredAt: now,
          cause: cause,
        );

        expect(error.cause, equals(cause));
      });
    });

    group('ChannelSyncError', () {
      test('contains channel, type, message, occurredAt', () {
        final error = ChannelSyncError(
          channelId,
          SyncErrorType.versionMismatch,
          'Version mismatch',
          occurredAt: now,
        );

        expect(error.channel, equals(channelId));
        expect(error.type, equals(SyncErrorType.versionMismatch));
        expect(error.message, equals('Version mismatch'));
        expect(error.occurredAt, equals(now));
        expect(error.cause, isNull);
      });
    });

    group('StorageSyncError', () {
      test('contains type, message, occurredAt', () {
        final error = StorageSyncError(
          SyncErrorType.storageFailure,
          'Disk full',
          occurredAt: now,
        );

        expect(error.type, equals(SyncErrorType.storageFailure));
        expect(error.message, equals('Disk full'));
        expect(error.occurredAt, equals(now));
      });
    });

    group('TransformSyncError', () {
      test('contains message, occurredAt, optional channel', () {
        final error = TransformSyncError(
          'Decryption failed',
          occurredAt: now,
          channel: channelId,
        );

        expect(error.message, equals('Decryption failed'));
        expect(error.occurredAt, equals(now));
        expect(error.channel, equals(channelId));
      });

      test('channel can be null', () {
        final error = TransformSyncError('Transform error', occurredAt: now);

        expect(error.channel, isNull);
      });
    });

    group('BufferOverflowError', () {
      test('contains channel, stream, author, bufferSize', () {
        final error = BufferOverflowError(
          channelId,
          streamId,
          peerId,
          1000,
          'Buffer overflow',
          occurredAt: now,
        );

        expect(error.channel, equals(channelId));
        expect(error.stream, equals(streamId));
        expect(error.author, equals(peerId));
        expect(error.bufferSize, equals(1000));
        expect(error.message, equals('Buffer overflow'));
        expect(error.occurredAt, equals(now));
      });
    });

    group('SyncErrorType', () {
      test('enum has all expected values', () {
        expect(SyncErrorType.values, contains(SyncErrorType.peerUnreachable));
        expect(SyncErrorType.values, contains(SyncErrorType.peerTimeout));
        expect(SyncErrorType.values, contains(SyncErrorType.messageCorrupted));
        expect(SyncErrorType.values, contains(SyncErrorType.messageTooLarge));
        expect(SyncErrorType.values, contains(SyncErrorType.versionMismatch));
        expect(SyncErrorType.values, contains(SyncErrorType.storageFailure));
        expect(SyncErrorType.values, contains(SyncErrorType.storageFull));
        expect(SyncErrorType.values, contains(SyncErrorType.transformFailure));
        expect(SyncErrorType.values, contains(SyncErrorType.protocolError));
        expect(SyncErrorType.values, contains(SyncErrorType.bufferOverflow));
        expect(SyncErrorType.values, contains(SyncErrorType.notAMember));
      });
    });

    group('Sealed class exhaustiveness', () {
      test('pattern matching compiles without errors', () {
        final error =
            PeerSyncError(
                  peerId,
                  SyncErrorType.peerTimeout,
                  'Test',
                  occurredAt: now,
                )
                as SyncError;

        // This should compile - sealed classes enable exhaustive pattern matching
        final result = switch (error) {
          PeerSyncError() => 'peer',
          ChannelSyncError() => 'channel',
          StorageSyncError() => 'storage',
          TransformSyncError() => 'transform',
          BufferOverflowError() => 'buffer',
        };

        expect(result, equals('peer'));
      });
    });
  });
}
