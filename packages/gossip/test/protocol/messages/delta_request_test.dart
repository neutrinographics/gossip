import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/protocol/messages/delta_request.dart';

void main() {
  group('DeltaRequest', () {
    test('creates delta request with missing entries info', () {
      final sender = NodeId('sender-1');
      final channelId = ChannelId('channel-1');
      final streamId = StreamId('stream-1');
      final since = VersionVector({NodeId('node-1'): 5});

      final request = DeltaRequest(
        sender: sender,
        channelId: channelId,
        streamId: streamId,
        since: since,
      );

      expect(request.sender, equals(sender));
      expect(request.channelId, equals(channelId));
      expect(request.streamId, equals(streamId));
      expect(request.since, equals(since));
    });
  });
}
