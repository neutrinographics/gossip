import 'dart:typed_data';

import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/hlc.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
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
