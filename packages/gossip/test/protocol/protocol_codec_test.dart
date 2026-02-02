import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/protocol/messages/ping.dart';
import 'package:gossip/src/protocol/messages/ack.dart';
import 'package:gossip/src/protocol/messages/ping_req.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';
import 'package:gossip/src/protocol/messages/delta_request.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:gossip/src/protocol/values/stream_digest.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';

void main() {
  group('ProtocolCodec', () {
    test('encode and decode Ping message', () {
      final codec = ProtocolCodec();
      final sender = NodeId('peer1');
      final ping = Ping(sender: sender, sequence: 42);

      final bytes = codec.encode(ping);
      final decoded = codec.decode(bytes);

      expect(decoded, isA<Ping>());
      final decodedPing = decoded as Ping;
      expect(decodedPing.sender, equals(sender));
      expect(decodedPing.sequence, equals(42));
    });

    test('encode and decode Ack message', () {
      final codec = ProtocolCodec();
      final sender = NodeId('peer2');
      final ack = Ack(sender: sender, sequence: 123);

      final bytes = codec.encode(ack);
      final decoded = codec.decode(bytes);

      expect(decoded, isA<Ack>());
      final decodedAck = decoded as Ack;
      expect(decodedAck.sender, equals(sender));
      expect(decodedAck.sequence, equals(123));
    });

    test('encode and decode PingReq message', () {
      final codec = ProtocolCodec();
      final sender = NodeId('peer1');
      final target = NodeId('peer3');
      final pingReq = PingReq(sender: sender, sequence: 456, target: target);

      final bytes = codec.encode(pingReq);
      final decoded = codec.decode(bytes);

      expect(decoded, isA<PingReq>());
      final decodedPingReq = decoded as PingReq;
      expect(decodedPingReq.sender, equals(sender));
      expect(decodedPingReq.sequence, equals(456));
      expect(decodedPingReq.target, equals(target));
    });

    test('encode and decode DigestRequest message', () {
      final codec = ProtocolCodec();
      final sender = NodeId('peer1');
      final channelId = ChannelId('channel1');
      final streamId = StreamId('stream1');
      final version = VersionVector({sender: 5});
      final streamDigest = StreamDigest(streamId: streamId, version: version);
      final channelDigest = ChannelDigest(
        channelId: channelId,
        streams: [streamDigest],
      );
      final request = DigestRequest(sender: sender, digests: [channelDigest]);

      final bytes = codec.encode(request);
      final decoded = codec.decode(bytes);

      expect(decoded, isA<DigestRequest>());
      final decodedRequest = decoded as DigestRequest;
      expect(decodedRequest.sender, equals(sender));
      expect(decodedRequest.digests, hasLength(1));
      expect(decodedRequest.digests[0].channelId, equals(channelId));
      expect(decodedRequest.digests[0].streams, hasLength(1));
      expect(decodedRequest.digests[0].streams[0].streamId, equals(streamId));
      expect(decodedRequest.digests[0].streams[0].version[sender], equals(5));
    });

    test('encode and decode DigestResponse message', () {
      final codec = ProtocolCodec();
      final sender = NodeId('peer2');
      final channelId = ChannelId('channel1');
      final streamId = StreamId('stream1');
      final author = NodeId('author1');
      final version = VersionVector({author: 3});
      final streamDigest = StreamDigest(streamId: streamId, version: version);
      final channelDigest = ChannelDigest(
        channelId: channelId,
        streams: [streamDigest],
      );
      final response = DigestResponse(sender: sender, digests: [channelDigest]);

      final bytes = codec.encode(response);
      final decoded = codec.decode(bytes);

      expect(decoded, isA<DigestResponse>());
      final decodedResponse = decoded as DigestResponse;
      expect(decodedResponse.sender, equals(sender));
      expect(decodedResponse.digests, hasLength(1));
      expect(decodedResponse.digests[0].channelId, equals(channelId));
      expect(decodedResponse.digests[0].streams, hasLength(1));
      expect(decodedResponse.digests[0].streams[0].streamId, equals(streamId));
      expect(decodedResponse.digests[0].streams[0].version[author], equals(3));
    });

    test('encode and decode DeltaRequest message', () {
      final codec = ProtocolCodec();
      final sender = NodeId('peer1');
      final channelId = ChannelId('channel1');
      final streamId = StreamId('stream1');
      final author = NodeId('author1');
      final since = VersionVector({author: 2});
      final request = DeltaRequest(
        sender: sender,
        channelId: channelId,
        streamId: streamId,
        since: since,
      );

      final bytes = codec.encode(request);
      final decoded = codec.decode(bytes);

      expect(decoded, isA<DeltaRequest>());
      final decodedRequest = decoded as DeltaRequest;
      expect(decodedRequest.sender, equals(sender));
      expect(decodedRequest.channelId, equals(channelId));
      expect(decodedRequest.streamId, equals(streamId));
      expect(decodedRequest.since[author], equals(2));
    });

    test('encode and decode DeltaResponse message', () {
      final codec = ProtocolCodec();
      final sender = NodeId('peer2');
      final channelId = ChannelId('channel1');
      final streamId = StreamId('stream1');
      final author = NodeId('author1');

      // Create test log entries
      final entry1 = LogEntry(
        author: author,
        sequence: 1,
        timestamp: Hlc(1000, 0),
        payload: Uint8List.fromList([1, 2, 3]),
      );
      final entry2 = LogEntry(
        author: author,
        sequence: 2,
        timestamp: Hlc(2000, 1),
        payload: Uint8List.fromList([4, 5, 6]),
      );

      final response = DeltaResponse(
        sender: sender,
        channelId: channelId,
        streamId: streamId,
        entries: [entry1, entry2],
      );

      final bytes = codec.encode(response);
      final decoded = codec.decode(bytes);

      expect(decoded, isA<DeltaResponse>());
      final decodedResponse = decoded as DeltaResponse;
      expect(decodedResponse.sender, equals(sender));
      expect(decodedResponse.channelId, equals(channelId));
      expect(decodedResponse.streamId, equals(streamId));
      expect(decodedResponse.entries, hasLength(2));

      // Verify first entry
      expect(decodedResponse.entries[0].author, equals(author));
      expect(decodedResponse.entries[0].sequence, equals(1));
      expect(decodedResponse.entries[0].timestamp, equals(Hlc(1000, 0)));
      expect(
        decodedResponse.entries[0].payload,
        equals(Uint8List.fromList([1, 2, 3])),
      );

      // Verify second entry
      expect(decodedResponse.entries[1].author, equals(author));
      expect(decodedResponse.entries[1].sequence, equals(2));
      expect(decodedResponse.entries[1].timestamp, equals(Hlc(2000, 1)));
      expect(
        decodedResponse.entries[1].payload,
        equals(Uint8List.fromList([4, 5, 6])),
      );
    });
  });
}
