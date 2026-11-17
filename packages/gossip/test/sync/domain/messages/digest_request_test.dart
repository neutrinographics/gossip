// Translated from gossip-kt
// `src/test/kotlin/com/neutrinographics/gossip/sync/domain/messages/DigestRequestTest.kt`
// (d902a61).
import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/messages/digest_response.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';

void main() {
  final sender = NodeId('n');
  final c1 = ChannelId('c1');
  final c2 = ChannelId('c2');

  ChannelDigest digest(ChannelId id) => ChannelDigest(
    channelId: id,
    streams: [
      StreamDigest(streamId: StreamId('s'), version: VersionVector.empty),
    ],
  );

  group('DigestRequest', () {
    test('a request names its digested and its announced channels alike', () {
      final r = DigestRequest(
        sender: sender,
        digests: [digest(c1)],
        announced: [c2],
      );
      expect(r.namedChannels, {c1, c2});
    });

    test('a request announces nothing unless told to', () {
      expect(
        DigestRequest(sender: sender, digests: [digest(c1)]).announced,
        isEmpty,
      );
    });
  });

  group('DigestResponse', () {
    test('a response names only what it digests', () {
      expect(
        DigestResponse(sender: sender, digests: [digest(c1)]).namedChannels,
        {c1},
      );
    });
  });
}
