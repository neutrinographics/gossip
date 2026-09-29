import 'dart:async';
import 'dart:typed_data';

import 'package:gossip/src/shared/domain/errors/sync_error.dart';
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

/// The 2026-08-31 incident shape: a peer with a hole in its history for one
/// author (a surplus range far above our coverage, nothing joining it to
/// what we hold) and no way to say the missing range is gone for good (no
/// compaction floor — a pre-floor build). Without suppression, every
/// exchange re-ships the whole surplus range and we reject it every time, at
/// full gossip cadence, forever.
///
/// The hole is below the surplus rather than at the very start of the log,
/// so that the peer answers where it was asked to and the hole it cannot
/// fill opens after that — the shape the incident had. Where the log is cut
/// off at the very start instead, the answer is still the answer, because it
/// names the request it answers; the second pin below is that case.
void main() {
  final channelId = ChannelId('stalled-channel');
  final streamId = StreamId('data');

  LogEntry entryOf(NodeId author, int seq) => LogEntry(
    author: author,
    sequence: seq,
    timestamp: Hlc(1000 + seq, 0),
    payload: Uint8List.fromList([seq % 256]),
  );

  List<LogEntry> entriesOf(
    NodeId author, {
    required int from,
    required int to,
  }) => [for (var seq = from; seq <= to; seq++) entryOf(author, seq)];

  /// Taps every frame [from] sends toward [to], answering with a counter of
  /// how many delta requests asked for [streamId] from each position.
  int Function(int since) tapAsks(TestNetwork network, String from, String to) {
    final sinceValues = <int>[];
    final codec = SyncMessageCodec(wireVersion: WireVersion.v2);
    network.corruptLink(from, to, (bytes) {
      final decoded = codec.decode(bytes);
      if (decoded is DeltaRequest && decoded.streamId == streamId) {
        sinceValues.add(decoded.since[network[to].id]);
      }
      return bytes;
    });
    return (since) => sinceValues.where((v) => v == since).length;
  }

  /// Runs rounds until the first request for the range is on the wire, then
  /// two more for the exchange it opens.
  ///
  /// Bounded rather than a fixed count: how many rounds discovery takes
  /// before the first request leaves is the dispatchers' business, and a
  /// fixed count that happens to cover it today pins the scheduler's timing
  /// rather than the suppression.
  Future<void> runUntilFirstAsk(
    TestNetwork network,
    int Function(int) asksFrom,
  ) async {
    for (var round = 0; round < 10 && asksFrom(0) == 0; round++) {
      await network.runRounds(1);
    }
    await network.runRounds(2);
  }

  test('a stalled range is requested once, then suppressed, then probed on '
      'the backoff cadence', () async {
    final network = await TestNetwork.create(['truncated', 'fresh']);
    addTearDown(network.dispose);
    final truncated = network['truncated'];
    final fresh = network['fresh'];

    await network.connect('truncated', 'fresh');
    await network.setupChannel(channelId, streamId);

    // The truncated peer holds 1..10 of its own authorship and then
    // nothing until 149 — no floor recorded, so it cannot write 11..148
    // off as compacted.
    await truncated.entryRepository.appendAll(
      channelId,
      streamId,
      entriesOf(truncated.id, from: 1, to: 10) +
          entriesOf(truncated.id, from: 149, to: 208),
    );

    final asksFrom = tapAsks(network, 'fresh', 'truncated');

    await network.startAll();
    await runUntilFirstAsk(network, asksFrom);

    expect(
      asksFrom(0),
      equals(1),
      reason: 'exactly one request asks for the range before suppression',
    );

    // Live data still converges while the range is suppressed.
    await fresh.write(channelId, streamId, [1]);
    await network.runRounds(3);
    expect(
      await truncated.entryCount(channelId, streamId),
      71,
      reason: '70 seeded + 1 live entry',
    );

    // The answer carried 1..10, so a probe of the hole asks from 10.
    final probesBefore = asksFrom(10);
    // 60s of fake clock. The probe window opens ~30s in, but quiescence
    // pacing slows a converged link to one exchange per ~30s, so the
    // horizon must cover window-open plus a full paced interval to
    // guarantee an exchange carries the probe. A second probe is
    // impossible here: the re-arm doubles the backoff to 60s.
    await network.runRounds(60);
    expect(
      asksFrom(10) - probesBefore,
      1,
      reason:
          'exactly one probe when the window opens, then re-armed '
          'with doubled backoff',
    );
  });

  test('a peer cut off at the start is answering, so its hole is diagnosed '
      'and suppressed', () async {
    // The case content alone could not read: a peer whose history for an
    // author is cut off at the very start, with no floor to say so,
    // answers above everything we asked for — indistinguishable by
    // content from a reactive push, and so, before identity, diagnosed as
    // nothing at all and re-asked at cadence forever. Named as the answer
    // to the request it answers, the same response is diagnosed like any
    // other: the hole is recorded, reported once, and the range
    // suppressed to the probe cadence.
    final network = await TestNetwork.create(['truncated', 'fresh']);
    addTearDown(network.dispose);
    final truncated = network['truncated'];
    final fresh = network['fresh'];

    await network.connect('truncated', 'fresh');
    await network.setupChannel(channelId, streamId);

    await truncated.entryRepository.appendAll(
      channelId,
      streamId,
      entriesOf(truncated.id, from: 149, to: 208),
    );

    final asksFrom = tapAsks(network, 'fresh', 'truncated');
    final holes = <SyncError>[];
    final subscription = fresh.coordinator.errors
        .where((error) => error.message.contains('sequence hole'))
        .listen(holes.add);
    addTearDown(subscription.cancel);

    await network.startAll();
    await runUntilFirstAsk(network, asksFrom);

    expect(
      asksFrom(0),
      equals(1),
      reason: 'the first exchange asks for the range',
    );
    expect(
      holes,
      hasLength(1),
      reason: 'the hole in an answer is reported once',
    );

    // 60s of fake clock: the 30s window opens once, so the range is asked
    // for exactly one more time — the probe — rather than at every
    // exchange.
    await network.runRounds(60);
    expect(
      asksFrom(0),
      equals(2),
      reason:
          'the diagnosis and one probe: the range is suppressed in '
          'between, not re-asked at cadence',
    );
    expect(
      holes,
      hasLength(1),
      reason: 'the same hole is diagnosed once, not once per probe',
    );
    expect(
      await fresh.entryCount(channelId, streamId),
      0,
      reason: 'the surplus range never lands over the gap',
    );
  });

  test(
    'the stalled range arriving from a third peer lifts the suppression',
    () async {
      final network = await TestNetwork.create([
        'truncated',
        'fresh',
        'archive',
      ]);
      addTearDown(network.dispose);
      final truncated = network['truncated'];

      await network.connectAll();
      await network.setupChannel(channelId, streamId);

      await truncated.entryRepository.appendAll(
        channelId,
        streamId,
        entriesOf(truncated.id, from: 1, to: 10) +
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
        reason:
            'suppression toward the truncated peer must not block '
            'obtaining the range from the archive',
      );
      // The truncated node itself can never recover 11..148 — its own
      // high-water vector already claims them; that is what the hole in its
      // history means. Convergence is asserted for the healthy pair.
      expect(
        await network.hasConverged(
          channelId,
          streamId,
          nodes: ['fresh', 'archive'],
        ),
        isTrue,
      );
    },
  );
}
