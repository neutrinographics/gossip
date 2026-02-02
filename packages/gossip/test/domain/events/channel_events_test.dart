import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/domain/events/domain_event.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/domain/results/compaction_result.dart';
import 'package:gossip/src/domain/errors/sync_error.dart';

void main() {
  group('Channel Events', () {
    final channelId = ChannelId('channel-1');
    final streamId = StreamId('stream-1');
    final memberId = NodeId('member-1');
    final now = DateTime(2024, 1, 15, 12, 0, 0);

    group('ChannelCreated', () {
      test('contains channelId', () {
        final event = ChannelCreated(channelId, occurredAt: now);

        expect(event.channelId, equals(channelId));
        expect(event.occurredAt, equals(now));
      });
    });

    group('ChannelRemoved', () {
      test('contains channelId', () {
        final event = ChannelRemoved(channelId, occurredAt: now);

        expect(event.channelId, equals(channelId));
        expect(event.occurredAt, equals(now));
      });
    });

    group('MemberAdded', () {
      test('contains channelId and memberId', () {
        final event = MemberAdded(channelId, memberId, occurredAt: now);

        expect(event.channelId, equals(channelId));
        expect(event.memberId, equals(memberId));
        expect(event.occurredAt, equals(now));
      });
    });

    group('MemberRemoved', () {
      test('contains channelId and memberId', () {
        final event = MemberRemoved(channelId, memberId, occurredAt: now);

        expect(event.channelId, equals(channelId));
        expect(event.memberId, equals(memberId));
        expect(event.occurredAt, equals(now));
      });
    });

    group('StreamCreated', () {
      test('contains channelId and streamId', () {
        final event = StreamCreated(channelId, streamId, occurredAt: now);

        expect(event.channelId, equals(channelId));
        expect(event.streamId, equals(streamId));
        expect(event.occurredAt, equals(now));
      });
    });

    group('EntryAppended', () {
      test('contains channelId, streamId, entry', () {
        final entry = LogEntry(
          author: memberId,
          sequence: 1,
          timestamp: Hlc(1000, 0),
          payload: Uint8List.fromList([1, 2, 3]),
        );
        final event = EntryAppended(
          channelId,
          streamId,
          entry,
          occurredAt: now,
        );

        expect(event.channelId, equals(channelId));
        expect(event.streamId, equals(streamId));
        expect(event.entry, equals(entry));
        expect(event.occurredAt, equals(now));
      });
    });

    group('EntriesMerged', () {
      test('contains channelId, streamId, entries, newVersion', () {
        final entries = [
          LogEntry(
            author: memberId,
            sequence: 1,
            timestamp: Hlc(1000, 0),
            payload: Uint8List.fromList([1, 2, 3]),
          ),
        ];
        final version = VersionVector({memberId: 1});
        final event = EntriesMerged(
          channelId,
          streamId,
          entries,
          version,
          occurredAt: now,
        );

        expect(event.channelId, equals(channelId));
        expect(event.streamId, equals(streamId));
        expect(event.entries, equals(entries));
        expect(event.newVersion, equals(version));
        expect(event.occurredAt, equals(now));
      });
    });

    group('StreamCompacted', () {
      test('contains channelId, streamId, result', () {
        final result = CompactionResult(
          entriesRemoved: 10,
          entriesRetained: 5,
          bytesFreed: 500,
          oldBaseVersion: VersionVector.empty,
          newBaseVersion: VersionVector({memberId: 5}),
        );
        final event = StreamCompacted(
          channelId,
          streamId,
          result,
          occurredAt: now,
        );

        expect(event.channelId, equals(channelId));
        expect(event.streamId, equals(streamId));
        expect(event.result, equals(result));
        expect(event.occurredAt, equals(now));
      });
    });

    group('BufferOverflowOccurred', () {
      test('contains channelId, streamId, author, droppedCount', () {
        final event = BufferOverflowOccurred(
          channelId,
          streamId,
          memberId,
          5,
          occurredAt: now,
        );

        expect(event.channelId, equals(channelId));
        expect(event.streamId, equals(streamId));
        expect(event.author, equals(memberId));
        expect(event.droppedCount, equals(5));
        expect(event.occurredAt, equals(now));
      });
    });

    group('NonMemberEntriesRejected', () {
      test('contains channelId, streamId, rejectedCount, unknownAuthors', () {
        final unknownAuthors = {NodeId('unknown-1'), NodeId('unknown-2')};
        final event = NonMemberEntriesRejected(
          channelId,
          streamId,
          3,
          unknownAuthors,
          occurredAt: now,
        );

        expect(event.channelId, equals(channelId));
        expect(event.streamId, equals(streamId));
        expect(event.rejectedCount, equals(3));
        expect(event.unknownAuthors, equals(unknownAuthors));
        expect(event.occurredAt, equals(now));
      });
    });

    group('SyncErrorOccurred', () {
      test('contains error', () {
        final syncError = PeerSyncError(
          memberId,
          SyncErrorType.peerTimeout,
          'Timeout',
          occurredAt: now,
        );
        final event = SyncErrorOccurred(syncError, occurredAt: now);

        expect(event.error, equals(syncError));
        expect(event.occurredAt, equals(now));
      });
    });
  });
}
