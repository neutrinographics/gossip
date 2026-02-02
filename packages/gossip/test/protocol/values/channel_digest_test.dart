import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/protocol/values/stream_digest.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';

void main() {
  group('ChannelDigest', () {
    test('equality works correctly', () {
      final channelId = ChannelId('channel-1');
      final stream1 = StreamDigest(
        streamId: StreamId('stream-1'),
        version: VersionVector({NodeId('node-1'): 5}),
      );
      final stream2 = StreamDigest(
        streamId: StreamId('stream-2'),
        version: VersionVector({NodeId('node-1'): 3}),
      );

      final digest1 = ChannelDigest(
        channelId: channelId,
        streams: [stream1, stream2],
      );
      final digest2 = ChannelDigest(
        channelId: channelId,
        streams: [stream1, stream2],
      );

      expect(digest1, equals(digest2));
      expect(digest1.hashCode, equals(digest2.hashCode));
    });
  });
}
