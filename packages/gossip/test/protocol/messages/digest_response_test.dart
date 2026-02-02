import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';

void main() {
  group('DigestResponse', () {
    test('creates digest response with sender and digests', () {
      final sender = NodeId('sender-1');
      final channelId = ChannelId('channel-1');
      final digest = ChannelDigest(channelId: channelId, streams: []);

      final response = DigestResponse(sender: sender, digests: [digest]);

      expect(response.sender, equals(sender));
      expect(response.digests, hasLength(1));
      expect(response.digests[0].channelId, equals(channelId));
    });
  });
}
