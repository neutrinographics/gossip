import 'dart:typed_data';

import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';
import 'package:gossip/src/protocol/values/channel_digest.dart';
import 'package:gossip/src/protocol/values/stream_digest.dart';
import 'package:test/test.dart';

import 'gossip_engine_test_harness.dart';

void main() {
  final channelId = ChannelId('ch1');
  final streamId = StreamId('s1');
  final authorA = NodeId('author-a');
  final authorB = NodeId('author-b');

  LogEntry entryOf(NodeId author, int seq, int tsMs) => LogEntry(
    author: author,
    sequence: seq,
    timestamp: Hlc(tsMs, 0),
    payload: Uint8List.fromList([seq]),
  );

  DeltaResponse deltaOf(List<LogEntry> entries) => DeltaResponse(
    sender: NodeId('peer1'),
    channelId: channelId,
    streamId: streamId,
    entries: entries,
  );

  Future<GossipEngineTestHarness> harnessAt(
    Map<NodeId, int> versions,
  ) async {
    final h = GossipEngineTestHarness();
    h.createChannel('ch1', streamIds: ['s1']);
    for (final MapEntry(key: author, value: maxSeq) in versions.entries) {
      for (var i = 1; i <= maxSeq; i++) {
        await h.entryRepository.append(
          channelId,
          streamId,
          entryOf(author, i, 1000 + i),
        );
      }
    }
    return h;
  }

  group('handleDeltaResponse contiguity guard', () {
    test(
      'a gapped entry is NOT merged and does not advance the version vector',
      () async {
        final h = await harnessAt({authorA: 5});

        // A push of seq 11 while 6-10 are missing.
        await h.engine.handleDeltaResponse(deltaOf([entryOf(authorA, 11, 2011)]));

        final all = await h.entryRepository.getAll(channelId, streamId);
        expect(
          all.map((e) => e.sequence),
          equals([1, 2, 3, 4, 5]),
          reason:
              'seq 11 must be dropped — merging it would advance the version '
              'vector to 11 and strand 6-10 forever',
        );
        final vv = await h.entryRepository.getVersionVector(channelId, streamId);
        expect(vv[authorA], equals(5));
      },
    );

    test('the next contiguous entry IS merged (fast-path)', () async {
      final h = await harnessAt({authorA: 5});

      await h.engine.handleDeltaResponse(deltaOf([entryOf(authorA, 6, 2006)]));

      final all = await h.entryRepository.getAll(channelId, streamId);
      expect(all.map((e) => e.sequence), equals([1, 2, 3, 4, 5, 6]));
    });

    test(
      'a gapped SOLICITED response emits a diagnosable error — once per '
      'gap, not per round (COR3-1 stopgap)',
      () async {
        final h = await harnessAt({authorA: 5});
        final peer = h.addPeer('peer1');

        // Arm a pending pull to peer1 (so the delta response is solicited).
        Future<void> solicit() => h.engine.handleDigestResponse(
          DigestResponse(
            sender: peer.id,
            digests: [
              ChannelDigest(
                channelId: channelId,
                streams: [
                  StreamDigest(
                    streamId: streamId,
                    version: VersionVector({authorA: 20}),
                  ),
                ],
              ),
            ],
          ),
        );

        await solicit();
        // The responder answers with a hole where we need data (it
        // compacted 6-10): everything is dropped. Before the fix this was
        // fully silent — the defining symptom of the COR3-1 lockout.
        await h.engine.handleDeltaResponse(
          deltaOf([entryOf(authorA, 11, 2011), entryOf(authorA, 12, 2012)]),
        );

        expect(h.mergedEntries, isEmpty);
        expect(h.errors, hasLength(1), reason: 'the gap must be reported');
        expect(h.errors.single.message, contains('6'));
        expect(h.errors.single.message, contains('11'));

        // The identical exchange repeats every round while the condition
        // persists — the error must not repeat with it.
        await solicit();
        await h.engine.handleDeltaResponse(
          deltaOf([entryOf(authorA, 11, 2011), entryOf(authorA, 12, 2012)]),
        );
        expect(h.errors, hasLength(1), reason: 'same gap reported once');
      },
    );

    test(
      'a gapped UNSOLICITED push is dropped without emitting an error — '
      'lagging behind a reactive push is routine',
      () async {
        final h = await harnessAt({authorA: 5});
        h.addPeer('peer1');

        // No pending pull: this is a reactive push of the writer's newest
        // entry while we are still behind. Anti-entropy will catch us up.
        await h.engine.handleDeltaResponse(deltaOf([entryOf(authorA, 11, 2011)]));

        expect(h.mergedEntries, isEmpty);
        expect(h.errors, isEmpty);
      },
    );

    test(
      'overlapping delta responses for one stream merge cleanly — no '
      'partial batches, no spurious errors, no double-reporting (COR3-9)',
      () async {
        final h = GossipEngineTestHarness();
        final peerA = h.addPeer('peerA');
        final peerB = h.addPeer('peerB');
        h.createChannel('ch1', streamIds: ['s1']);

        DeltaResponse from(NodeId sender, List<int> seqs) => DeltaResponse(
          sender: sender,
          channelId: channelId,
          streamId: streamId,
          entries: [for (final s in seqs) entryOf(authorA, s, 2000 + s)],
        );

        // Two peers answer with overlapping batches concurrently — routine
        // after a reconnect (sync-on-connect + periodic round coincide).
        await Future.wait([
          h.engine.handleDeltaResponse(from(peerA.id, [1, 2, 3])),
          h.engine.handleDeltaResponse(from(peerB.id, [1, 2, 3, 4])),
        ]);

        expect(h.errors, isEmpty);
        final stored = await h.entryRepository.getAll(channelId, streamId);
        expect(stored.map((e) => e.sequence), equals([1, 2, 3, 4]));
        // Every entry reported exactly once across the merge callbacks.
        final reported =
            h.mergedEntries.expand((m) => m.entries).map((e) => e.sequence).toList()
              ..sort();
        expect(reported, equals([1, 2, 3, 4]));
      },
    );

    test(
      'an entry tying the tail timestamp flags out-of-order (COR3-27)',
      () async {
        final h = GossipEngineTestHarness();
        h.addPeer('peer1');
        h.createChannel('ch1', streamIds: ['s1']);

        // Tail: author-b @ ts 2000.
        await h.entryRepository.append(
          channelId,
          streamId,
          entryOf(authorB, 1, 2000),
        );

        // author-a @ ts 2000 sorts BEFORE the tail (author tiebreak): the
        // repository inserts it before the tail, so an incremental fold in
        // arrival order would diverge from a rebuild. The tail is known
        // only by timestamp, so a timestamp tie must be treated as
        // possibly-out-of-order.
        await h.engine.handleDeltaResponse(
          deltaOf([entryOf(authorA, 1, 2000)]),
        );

        expect(h.mergedEntries.single.containsOutOfOrderEntries, isTrue);
      },
    );

    test(
      'entries rejected by the guard do not advance the HLC clock (COR3-10)',
      () async {
        final h = GossipEngineTestHarness(withHlcClock: true);
        h.addPeer('peer1');
        h.createChannel('ch1', streamIds: ['s1']);

        final before = h.hlcClock!.current;

        // Empty local VV, so seq 5 is non-contiguous → whole batch dropped.
        await h.engine.handleDeltaResponse(deltaOf([entryOf(authorA, 5, 2000)]));

        expect(h.mergedEntries, isEmpty);
        expect(
          h.hlcClock!.current,
          equals(before),
          reason: 'rejected entries must not drive the local clock',
        );
      },
    );

    test('accepts the contiguous prefix and drops entries past a gap',
        () async {
      final h = await harnessAt({authorA: 5});

      // 6,7 are contiguous; 9 sits past a gap at 8.
      await h.engine.handleDeltaResponse(
        deltaOf([
          entryOf(authorA, 6, 2006),
          entryOf(authorA, 7, 2007),
          entryOf(authorA, 9, 2009),
        ]),
      );

      final all = await h.entryRepository.getAll(channelId, streamId);
      expect(all.map((e) => e.sequence), equals([1, 2, 3, 4, 5, 6, 7]));
      final vv = await h.entryRepository.getVersionVector(channelId, streamId);
      expect(vv[authorA], equals(7));
    });

    test('per-author contiguity is independent (multi-author delta)',
        () async {
      final h = await harnessAt({authorA: 5, authorB: 2});

      // A:6 is contiguous; B:5 sits past a gap (B is at 2, missing 3,4).
      await h.engine.handleDeltaResponse(
        deltaOf([
          entryOf(authorA, 6, 2006),
          entryOf(authorB, 5, 2005),
        ]),
      );

      final vv = await h.entryRepository.getVersionVector(channelId, streamId);
      expect(vv[authorA], equals(6), reason: 'A contiguous entry accepted');
      expect(vv[authorB], equals(2), reason: 'B gapped entry dropped');
    });

    test('a normal contiguous multi-entry delta is fully applied '
        '(no regression)', () async {
      final h = await harnessAt({authorA: 5});

      await h.engine.handleDeltaResponse(
        deltaOf([
          entryOf(authorA, 6, 2006),
          entryOf(authorA, 7, 2007),
          entryOf(authorA, 8, 2008),
        ]),
      );

      final vv = await h.entryRepository.getVersionVector(channelId, streamId);
      expect(vv[authorA], equals(8));
    });
  });
}
