import 'package:test/test.dart';
import 'package:gossip/src/domain/results/digest.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';

void main() {
  group('Digest Types', () {
    final node1 = NodeId('node-1');
    final channelId = ChannelId('channel-1');
    final streamId = StreamId('stream-1');
    final version = VersionVector({node1: 5});

    group('StreamDigest', () {
      test('contains version vector', () {
        final digest = StreamDigest(version);

        expect(digest.version, equals(version));
      });
    });

    group('ChannelDigest', () {
      test('contains channelId and stream map', () {
        final streamDigest = StreamDigest(version);
        final streams = {streamId: streamDigest};
        final digest = ChannelDigest(channelId, streams);

        expect(digest.channelId, equals(channelId));
        expect(digest.streams, equals(streams));
      });
    });

    group('BatchedDigest', () {
      test('contains channel map', () {
        final streamDigest = StreamDigest(version);
        final channelDigest = ChannelDigest(channelId, {
          streamId: streamDigest,
        });
        final channels = {channelId: channelDigest};
        final digest = BatchedDigest(channels);

        expect(digest.channels, equals(channels));
      });

      test('isEmpty returns true when empty', () {
        final digest = BatchedDigest({});

        expect(digest.isEmpty, isTrue);
      });

      test('isEmpty returns false when not empty', () {
        final streamDigest = StreamDigest(version);
        final channelDigest = ChannelDigest(channelId, {
          streamId: streamDigest,
        });
        final digest = BatchedDigest({channelId: channelDigest});

        expect(digest.isEmpty, isFalse);
      });
    });
  });
}
