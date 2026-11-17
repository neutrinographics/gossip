// Translated from gossip-kt
// `src/test/kotlin/com/neutrinographics/gossip/sync/domain/services/DigestAnsweringTest.kt`
// (d902a61).
import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/shared/domain/value_objects/version_vector.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/services/digest_answering.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';

void main() {
  group('DigestAnswering', () {
    final sender = NodeId('peer');
    final a = NodeId('a');
    final b = NodeId('b');
    final c1 = ChannelId('c1');
    final c2 = ChannelId('c2');
    final s1 = StreamId('s1');
    final s2 = StreamId('s2');

    VersionVector vv(Map<NodeId, int> e) => VersionVector(e);
    StreamDigest sd(StreamId s, VersionVector v) =>
        StreamDigest(streamId: s, version: v);
    ChannelDigest cd(ChannelId c, List<StreamDigest> s) =>
        ChannelDigest(channelId: c, streams: s);

    test('an announced channel we hold is answered with our whole digest for '
        'it', () {
      final ours = cd(c1, [
        sd(s1, vv({a: 5})),
        sd(s2, vv({b: 2})),
      ]);
      final request = DigestRequest(
        sender: sender,
        digests: const [],
        announced: [c1],
      );
      expect(DigestAnswering.answer(request, [ours]), [ours]);
    });

    test('an announced channel we hold with no streams is answered with its '
        'empty digest, so the announcer learns we hold it', () {
      final ours = cd(c1, const []);
      final request = DigestRequest(
        sender: sender,
        digests: const [],
        announced: [c1],
      );
      expect(DigestAnswering.answer(request, [ours]), [ours]);
    });

    test('a digested channel is answered with the named streams we hold, and '
        'only those', () {
      final ours = cd(c1, [
        sd(s1, vv({a: 5})),
        sd(s2, vv({b: 2})),
      ]);
      final request = DigestRequest(
        sender: sender,
        digests: [
          cd(c1, [
            sd(s1, vv({a: 1})),
          ]),
        ],
      );
      expect(DigestAnswering.answer(request, [ours]), [
        cd(c1, [
          sd(s1, vv({a: 5})),
        ]),
      ]);
    });

    test('a named stream we do not hold is skipped', () {
      final ours = cd(c1, [
        sd(s1, vv({a: 5})),
      ]);
      final request = DigestRequest(
        sender: sender,
        digests: [
          cd(c1, [
            sd(s2, vv({a: 1})),
          ]),
        ],
      );
      expect(DigestAnswering.answer(request, [ours]), isEmpty);
    });

    // Originates in `gossip_engine_digest_filter_test.dart` ("omits streams
    // the requester already dominates"); kt's test is a translation of it.
    test('omits streams the requester already dominates, and the channel '
        'when none survives', () {
      final ours = cd(c1, [
        sd(s1, vv({a: 5})),
        sd(s2, vv({b: 2})),
      ]);
      final request = DigestRequest(
        sender: sender,
        digests: [
          cd(c1, [
            sd(s1, vv({a: 5, b: 1})),
            sd(s2, vv({b: 1})),
          ]),
        ],
      );
      expect(DigestAnswering.answer(request, [ours]), [
        cd(c1, [
          sd(s2, vv({b: 2})),
        ]),
      ]);

      final allDominated = DigestRequest(
        sender: sender,
        digests: [
          cd(c1, [
            sd(s1, vv({a: 5})),
            sd(s2, vv({b: 2})),
          ]),
        ],
      );
      expect(
        DigestAnswering.answer(allDominated, [ours]),
        isEmpty,
        reason: 'absent, not present with an empty stream list',
      );
    });

    test('a channel both announced and digested is answered as digested, '
        'once', () {
      final ours = cd(c1, [
        sd(s1, vv({a: 5})),
        sd(s2, vv({b: 2})),
      ]);
      final request = DigestRequest(
        sender: sender,
        digests: [
          cd(c1, [
            sd(s1, vv({a: 1})),
          ]),
        ],
        announced: [c1],
      );
      expect(DigestAnswering.answer(request, [ours]), [
        cd(c1, [
          sd(s1, vv({a: 5})),
        ]),
      ]);
    });

    test('a channel of ours the request did not name never appears', () {
      final ours = [
        cd(c1, [
          sd(s1, vv({a: 5})),
        ]),
        cd(c2, [
          sd(s1, vv({a: 9})),
        ]),
      ];
      final request = DigestRequest(
        sender: sender,
        digests: const [],
        announced: [c1],
      );
      expect(DigestAnswering.answer(request, ours).map((d) => d.channelId), [
        c1,
      ]);
    });

    test('a named channel we did not gather is skipped', () {
      final request = DigestRequest(
        sender: sender,
        digests: [
          cd(c2, [
            sd(s1, vv({a: 1})),
          ]),
        ],
        announced: [c1],
      );
      expect(DigestAnswering.answer(request, const []), isEmpty);
    });

    test('order is the request\'s — digested channels first, then '
        'announced', () {
      final ours = [
        cd(c1, [
          sd(s1, vv({a: 5})),
        ]),
        cd(c2, [
          sd(s1, vv({a: 9})),
        ]),
      ];
      final request = DigestRequest(
        sender: sender,
        digests: [
          cd(c2, [
            sd(s1, vv({a: 1})),
          ]),
        ],
        announced: [c1],
      );
      expect(DigestAnswering.answer(request, ours).map((d) => d.channelId), [
        c2,
        c1,
      ]);
    });
  });
}
