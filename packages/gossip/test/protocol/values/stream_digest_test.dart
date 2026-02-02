import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/protocol/values/stream_digest.dart';

void main() {
  group('StreamDigest', () {
    test('equality works correctly', () {
      final streamId = StreamId('stream-1');
      final version = VersionVector({NodeId('node-1'): 5});

      final digest1 = StreamDigest(streamId: streamId, version: version);
      final digest2 = StreamDigest(streamId: streamId, version: version);

      expect(digest1, equals(digest2));
      expect(digest1.hashCode, equals(digest2.hashCode));
    });

    test('different stream IDs are not equal', () {
      final version = VersionVector({NodeId('node-1'): 5});

      final digest1 = StreamDigest(
        streamId: StreamId('stream-1'),
        version: version,
      );
      final digest2 = StreamDigest(
        streamId: StreamId('stream-2'),
        version: version,
      );

      expect(digest1, isNot(equals(digest2)));
    });
  });
}
