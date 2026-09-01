import 'dart:typed_data';

import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';
import 'package:gossip/src/sync/domain/messages/delta_request.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';
import 'package:test/test.dart';

import '../../support/test_network.dart';

/// The 2026-08-31 incident shape: a peer whose history for one author is
/// truncated (first available far above our coverage) and who cannot say
/// the range is gone for good (no compaction floor — a pre-floor build).
/// Without suppression, every exchange re-ships the whole surplus range and
/// we reject it every time, at full gossip cadence, forever.
void main() {
  final channelId = ChannelId('stalled-channel');
  final streamId = StreamId('data');

  LogEntry entryOf(NodeId author, int seq) => LogEntry(
    author: author,
    sequence: seq,
    timestamp: Hlc(1000 + seq, 0),
    payload: Uint8List.fromList([seq % 256]),
  );

  List<LogEntry> entriesOf(NodeId author, {required int from, required int to}) =>
      [for (var seq = from; seq <= to; seq++) entryOf(author, seq)];

  test(
    'a stalled range is requested once, then suppressed, then probed on '
    'the backoff cadence',
    () async {
      final network = await TestNetwork.create(['truncated', 'fresh']);
      addTearDown(network.dispose);
      final truncated = network['truncated'];
      final fresh = network['fresh'];

      await network.connect('truncated', 'fresh');
      await network.setupChannel(channelId, streamId);

      // The truncated peer holds its own authorship only from 149 — no
      // floor recorded, so it cannot write the range off as compacted.
      await truncated.entryRepository.appendAll(
        channelId,
        streamId,
        entriesOf(truncated.id, from: 149, to: 208),
      );

      // Tap every frame fresh sends toward the truncated peer; decode is
      // version-agnostic, so the coordinator's emit version doesn't matter.
      final sinceValues = <int>[];
      final codec = SyncMessageCodec(wireVersion: WireVersion.v2);
      network.corruptLink('fresh', 'truncated', (bytes) {
        final decoded = codec.decode(bytes);
        if (decoded is DeltaRequest && decoded.streamId == streamId) {
          sinceValues.add(decoded.since[truncated.id]);
        }
        return bytes;
      });

      await network.startAll();
      await network.runRounds(3); // discovery + the one diagnosing exchange

      expect(
        sinceValues.where((v) => v == 0),
        hasLength(1),
        reason: 'exactly one request asks for the range before suppression',
      );

      // Live data still converges while the range is suppressed.
      await fresh.write(channelId, streamId, [1]);
      await network.runRounds(3);
      expect(
        await truncated.entryCount(channelId, streamId),
        61,
        reason: '60 seeded + 1 live entry',
      );

      final probesBefore = sinceValues.where((v) => v == 0).length;
      // 60s of fake clock. The probe window opens ~30s in, but quiescence
      // pacing slows a converged link to one exchange per ~30s, so the
      // horizon must cover window-open plus a full paced interval to
      // guarantee an exchange carries the probe. A second probe is
      // impossible here: the re-arm doubles the backoff to 60s.
      await network.runRounds(60);
      final probesAfter = sinceValues.where((v) => v == 0).length;
      expect(
        probesAfter - probesBefore,
        1,
        reason: 'exactly one probe when the window opens, then re-armed '
            'with doubled backoff',
      );
    },
  );

  test(
    'the stalled range arriving from a third peer lifts the suppression',
    () async {
      final network = await TestNetwork.create(['truncated', 'fresh', 'archive']);
      addTearDown(network.dispose);
      final truncated = network['truncated'];

      await network.connectAll();
      await network.setupChannel(channelId, streamId);

      await truncated.entryRepository.appendAll(
        channelId,
        streamId,
        entriesOf(truncated.id, from: 149, to: 208),
      );
      // The archive holds the whole history — the range IS obtainable.
      await network['archive'].entryRepository.appendAll(
        channelId,
        streamId,
        entriesOf(truncated.id, from: 1, to: 208),
      );

      await network.startAll();
      await network.runRounds(20);

      expect(
        await network['fresh'].entryCount(channelId, streamId),
        208,
        reason: 'suppression toward the truncated peer must not block '
            'obtaining the range from the archive',
      );
      // The truncated node itself can never recover 1..148 — its own
      // high-water vector already claims them; that is what being
      // truncated means. Convergence is asserted for the healthy pair.
      expect(
        await network.hasConverged(channelId, streamId, nodes: ['fresh', 'archive']),
        isTrue,
      );
    },
  );
}
