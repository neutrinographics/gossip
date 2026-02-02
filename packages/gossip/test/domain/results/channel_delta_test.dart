import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/domain/results/channel_delta.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';

void main() {
  group('ChannelDelta', () {
    final channelId = ChannelId('channel-1');
    final streamId1 = StreamId('stream-1');
    final streamId2 = StreamId('stream-2');
    final author = NodeId('node-1');

    final entry1 = LogEntry(
      author: author,
      sequence: 1,
      timestamp: Hlc(1000, 0),
      payload: Uint8List.fromList([1, 2, 3]), // 3 bytes
    );
    final entry2 = LogEntry(
      author: author,
      sequence: 2,
      timestamp: Hlc(2000, 0),
      payload: Uint8List.fromList([4, 5]), // 2 bytes
    );

    test('ChannelDelta contains channelId and entries map', () {
      final entries = {
        streamId1: [entry1, entry2],
      };
      final delta = ChannelDelta(channelId, entries);

      expect(delta.channelId, equals(channelId));
      expect(delta.entries, equals(entries));
    });

    test('totalEntries sums all entry list lengths', () {
      final entries = {
        streamId1: [entry1, entry2],
        streamId2: [entry1],
      };
      final delta = ChannelDelta(channelId, entries);

      expect(delta.totalEntries, equals(3));
    });

    test('totalBytes sums all entry sizes', () {
      final entries = {
        streamId1: [entry1, entry2], // (52+3) + (52+2) = 109
      };
      final delta = ChannelDelta(channelId, entries);

      // entry1: 52 + 3 = 55, entry2: 52 + 2 = 54 → total = 109
      expect(delta.totalBytes, equals(109));
    });

    test('totalEntries returns 0 for empty delta', () {
      final delta = ChannelDelta(channelId, {});

      expect(delta.totalEntries, equals(0));
    });

    test('totalBytes returns 0 for empty delta', () {
      final delta = ChannelDelta(channelId, {});

      expect(delta.totalBytes, equals(0));
    });
  });
}
