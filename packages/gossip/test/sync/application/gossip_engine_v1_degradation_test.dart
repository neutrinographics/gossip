import 'dart:convert';
import 'dart:typed_data';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';
import 'package:gossip/src/sync/domain/messages/delta_response.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

void main() {
  test('v1-mode truncation converges through repeated pulls; '
      'no frame ever carries hasMore', () async {
    final h = GossipEngineTestHarness(
      wireVersion: WireVersion.v1,
      maxMessageBytes: 4096,
    );
    final peer = h.addPeer('peer1');
    final channelId = ChannelId('ch1');
    final streamId = StreamId('s1');
    await h.createChannelWithStream(channelId, streamId);

    // 6 entries at ~2.5KB encoded each (v1 int-array) → one entry per
    // 4KB page → convergence needs multiple pulls.
    for (var seq = 1; seq <= 6; seq++) {
      await h.appendEntry(
        channelId,
        streamId,
        LogEntry(
          author: h.localNode,
          sequence: seq,
          timestamp: Hlc(1000 + seq, 0),
          payload: Uint8List.fromList(List.filled(600, 200)),
        ),
      );
    }

    final rawFrames = <Uint8List>[];
    final rawSub = peer.port.incoming.listen((m) => rawFrames.add(m.bytes));
    final (messages, sub) = h.captureMessages(peer);

    var since = VersionVector.empty;
    var received = 0;
    var pulls = 0;
    while (received < 6 && pulls < 10) {
      pulls++;
      await h.deliverDeltaRequest(
        from: peer,
        channelId: channelId,
        streamId: streamId,
        since: since,
      );
      final response = messages.whereType<DeltaResponse>().last;
      expect(
        response.hasMore,
        isFalse,
        reason: 'v1 wire never carries hasMore; decode defaults to false',
      );
      received += response.entries.length;
      since = VersionVector({h.localNode: received});
    }

    expect(received, equals(6), reason: 'all pages arrive across pulls');
    expect(pulls, greaterThan(1), reason: 'the backlog really was paginated');
    for (final frame in rawFrames) {
      expect(frame[0], lessThanOrEqualTo(6), reason: 'unprefixed v1 frames');
      final json =
          jsonDecode(utf8.decode(frame.sublist(1))) as Map<String, dynamic>;
      expect(json.containsKey('hasMore'), isFalse);
    }

    await rawSub.cancel();
    await sub.cancel();
    await h.dispose();
  });
}
