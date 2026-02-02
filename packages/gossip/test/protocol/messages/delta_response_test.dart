import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';

void main() {
  group('DeltaResponse', () {
    test('creates delta response with entries', () {
      final sender = NodeId('sender-1');
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');
      final entry = LogEntry(
        author: NodeId('author-1'),
        sequence: 1,
        timestamp: Hlc(1000, 0),
        payload: Uint8List.fromList([1, 2, 3]),
      );

      final response = DeltaResponse(
        sender: sender,
        channelId: channelId,
        streamId: streamId,
        entries: [entry],
      );

      expect(response.sender, equals(sender));
      expect(response.channelId, equals(channelId));
      expect(response.streamId, equals(streamId));
      expect(response.entries, hasLength(1));
      expect(response.entries[0].sequence, equals(1));
    });
  });
}
