import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';

void main() {
  group('DigestRequest', () {
    test('creates digest request with sender and digests', () {
      final sender = NodeId('sender-1');
      final channelId = ChannelId('channel-1');
      final digest = ChannelDigest(channelId: channelId, streams: []);

      final request = DigestRequest(sender: sender, digests: [digest]);

      expect(request.sender, equals(sender));
      expect(request.digests, hasLength(1));
      expect(request.digests[0].channelId, equals(channelId));
    });
  });
}
