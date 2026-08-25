import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/domain/interfaces/retention_policy.dart';

import '../../support/test_network.dart';

/// End-to-end (real Coordinator, real transport-shaped message bus) pins for
/// COR3-1 compaction-aware sync: a responder that pruned history below a
/// peer's position must report a floor the peer can adopt as truncated
/// history, instead of the peer dropping the survivors forever and
/// re-requesting an unobtainable range every round.
///
/// The unit-level version of scenario 1 already lives in
/// gossip_engine_compaction_floor_test.dart ("end to end" group); these
/// tests exercise the same guarantee through the full DSL (real Coordinator
/// lifecycle, real periodic gossip rounds, real message bus) plus the
/// transitive/returning-peer/prune-all cases that unit-level harnesses
/// can't easily stage.
void main() {
  final channelId = ChannelId('compaction-ch');
  final streamId = StreamId('compaction-s');

  /// Settles the reactive-push debounce (150ms) against the fake clock.
  ///
  /// `notifyLocalWrite` buffers raw appended entries and flushes them
  /// verbatim to whoever is reachable *when the debounce timer fires* — not
  /// whoever was reachable when the entries were written. Against a real
  /// clock the flush already happens (or is dropped, if nobody was
  /// reachable) within ~150ms, long before a fresh peer's connection
  /// establishes. Against the fake clock, time is frozen until a test
  /// advances it, so an unflushed batch can survive across a later
  /// `compact()` or a peer becoming reachable — handing that peer entries
  /// the sender no longer durably holds, bypassing the compaction floor
  /// entirely (the reactive push carries no floor). Call this right after a
  /// batch of writes and before compacting/connecting a new peer so each
  /// scenario below exercises ordinary digest/delta anti-entropy — not an
  /// artifact of the fake clock's frozen debounce window.
  Future<void> settlePendingPush(TestNetwork network) => network.runRounds(1);

  /// Counts messages crossing both directions of a link — see
  /// idle_quiescence_test.dart's `tapBoth` for the identity-tap pattern.
  void tapBoth(TestNetwork network, String a, String b, List<int> counter) {
    network.corruptLink(a, b, (bytes) {
      counter[0]++;
      return bytes;
    });
    network.corruptLink(b, a, (bytes) {
      counter[0]++;
      return bytes;
    });
  }

  test('late joiner vs compacted responder: floor adoption, content-checked, '
      'and traffic quiesces after convergence (COR3-1)', () async {
    final network = await TestNetwork.create(['a', 'b']);
    addTearDown(network.dispose);
    // Only A has the channel at first — B joins later, after A has
    // already compacted.
    await network.setupChannel(
      channelId,
      streamId,
      members: ['a'],
      retention: const CountBasedRetention(2),
    );
    await network['a'].start();

    for (var i = 1; i <= 5; i++) {
      await network['a'].write(channelId, streamId, [i]);
    }
    await settlePendingPush(network);

    final result = await network['a'].compact(channelId, streamId);
    expect(
      result,
      isNotNull,
      reason:
          'compaction must actually prune something, or this pin '
          'proves nothing',
    );
    expect(result!.entriesRemoved, equals(3));
    expect(await network['a'].entryCount(channelId, streamId), equals(2));

    // THEN B connects and starts.
    await network.joinChannel('b', channelId, streamId, existingMembers: ['a']);
    await network.connect('a', 'b');
    await network['b'].start();

    await network.runRounds(15);

    expect(
      await network.hasConverged(channelId, streamId, nodes: ['a', 'b']),
      isTrue,
      reason:
          'the late joiner must converge despite the responder having '
          'compacted below its (zero) starting position',
    );

    final bEntries = await network['b'].entries(channelId, streamId);
    expect(
      bEntries.map((e) => e.sequence).toList(),
      equals([4, 5]),
      reason:
          'B must hold EXACTLY the surviving entries — a content '
          'check, not just a count, so this actually proves floor '
          'adoption rather than "some sync happened"',
    );
    expect(
      bEntries.map((e) => e.payload.toList()).toList(),
      equals([
        [4],
        [5],
      ]),
    );

    // Breaking floor adoption reintroduces the audit's futile-resend
    // loop: the requester keeps re-asking for a range the responder can
    // never serve again, so idle traffic never decays. Tap the link and
    // confirm a later window is strictly quieter than an earlier one.
    final counter = [0];
    tapBoth(network, 'a', 'b', counter);

    await network.runRounds(30); // early idle window
    final earlyCount = counter[0];
    await network.runRounds(60); // let backoff/quiescence take hold
    counter[0] = 0;
    await network.runRounds(30); // late idle window, same width
    final lateCount = counter[0];

    expect(
      lateCount,
      lessThan(earlyCount),
      reason:
          'the futile-resend-loop symptom must stay dead: idle '
          'traffic decays after convergence instead of looping on an '
          'unobtainable range',
    );
  });

  test('transitive floor propagation: C joins via B only and never talks to A '
      '(adoptVersionFloor raises the adopter\'s own servable floor)', () async {
    final network = await TestNetwork.create(['a', 'b', 'c']);
    addTearDown(network.dispose);
    await network.setupChannel(
      channelId,
      streamId,
      members: ['a'],
      retention: const CountBasedRetention(2),
    );
    await network['a'].start();

    for (var i = 1; i <= 5; i++) {
      await network['a'].write(channelId, streamId, [i]);
    }
    await settlePendingPush(network);
    await network['a'].compact(channelId, streamId);

    // B connects to A and converges: adopts the floor, holds 4..5, and
    // never compacts anything itself (no compact() call on B, ever).
    await network.joinChannel('b', channelId, streamId, existingMembers: ['a']);
    await network.connect('a', 'b');
    await network['b'].start();
    await network.runRounds(15);

    expect(
      await network.hasConverged(channelId, streamId, nodes: ['a', 'b']),
      isTrue,
    );
    final bEntries = await network['b'].entries(channelId, streamId);
    expect(bEntries.map((e) => e.sequence).toList(), equals([4, 5]));

    // C connects to B ONLY — targeted connect, never to A.
    await network.joinChannel('c', channelId, streamId, existingMembers: ['b']);
    await network.connect('b', 'c');
    await network['c'].start();
    await network.runRounds(15);

    expect(
      await network.hasConverged(channelId, streamId, nodes: ['b', 'c']),
      isTrue,
      reason:
          'C must converge with B even though C never talks to A '
          'directly — this pins adoptVersionFloor raising B\'s own '
          'servable floor (getCompactionFloor serves adopted floors)',
    );
    final cEntries = await network['c'].entries(channelId, streamId);
    expect(
      cEntries.map((e) => e.sequence).toList(),
      equals([4, 5]),
      reason:
          'C must hold exactly the entries B was able to serve, '
          'transitively inherited from A\'s original compaction',
    );
  });

  test('returning peer below the floor: reconnect after the responder has '
      'compacted past the peer\'s last-known position', () async {
    final network = await TestNetwork.create(['a', 'b']);
    addTearDown(network.dispose);
    await network.setupChannel(
      channelId,
      streamId,
      members: ['a', 'b'],
      retention: const CountBasedRetention(2),
    );
    await network.connect('a', 'b');
    await network['a'].start();
    await network['b'].start();

    // A and B sync fully at 3 entries (both physically hold 1..3; no
    // compaction has happened yet).
    for (var i = 1; i <= 3; i++) {
      await network['a'].write(channelId, streamId, [i]);
    }
    await network.runRounds(10);
    expect(
      await network.hasConverged(channelId, streamId),
      isTrue,
      reason: 'both must be fully synced at 3 entries before B goes away',
    );

    // Disconnect B (network-level, not a coordinator stop — it stays
    // running, it just can't reach A).
    network.partition('b');

    // A appends up to 8 and compacts: CountBasedRetention(2) over 8
    // entries keeps 7..8, prunes 1..6 (floor {a: 6}).
    for (var i = 4; i <= 8; i++) {
      await network['a'].write(channelId, streamId, [i]);
    }
    await settlePendingPush(network); // dropped: B is unreachable now
    final result = await network['a'].compact(channelId, streamId);
    expect(result, isNotNull);
    expect(result!.entriesRemoved, equals(6));
    expect(await network['a'].entryCount(channelId, streamId), equals(2));

    final errors = <Object>[];
    network['b'].coordinator.errors.listen(errors.add);

    // B reconnects at {a: 3} — below the floor.
    network.heal('b');
    await network.runRounds(15);

    // B already held 1..3 from before it disconnected (nothing deletes a
    // peer's own already-held copy just because the sender later
    // compacted), so "converges" here means: it reaches 7..8 too, with
    // 4..6 correctly skipped as unobtainable rather than dropped with an
    // error or wedging the sync loop.
    final bEntries = await network['b'].entries(channelId, streamId);
    expect(
      bEntries.map((e) => e.sequence).toSet(),
      equals({1, 2, 3, 7, 8}),
      reason:
          'B keeps what it already had (1..3) and adopts the floor '
          'to accept the survivors (7..8) — 4..6 must never appear, '
          'because they are gone everywhere',
    );
    expect(
      errors,
      isEmpty,
      reason:
          'skipping the unobtainable 4..6 range via floor adoption '
          'must not surface as an error — it is designed behavior, not '
          'a fault',
    );
  });

  test('prune-all then new appends: a floor-only peer with no entries still '
      'accepts new contiguous history', () async {
    final network = await TestNetwork.create(['a', 'b']);
    addTearDown(network.dispose);
    await network.setupChannel(
      channelId,
      streamId,
      members: ['a'],
      retention: const CountBasedRetention(0), // legal: prunes everything
    );
    await network['a'].start();

    for (var i = 1; i <= 3; i++) {
      await network['a'].write(channelId, streamId, [i]);
    }
    await settlePendingPush(network);
    final result = await network['a'].compact(channelId, streamId);
    expect(result, isNotNull);
    expect(
      result!.entriesRetained,
      equals(0),
      reason: 'CountBasedRetention(0) must be legal and prune everything',
    );
    expect(await network['a'].entryCount(channelId, streamId), equals(0));

    await network.joinChannel('b', channelId, streamId, existingMembers: ['a']);
    await network.connect('a', 'b');
    await network['b'].start();
    await network.runRounds(15);

    // B adopts a pure floor (no survivors to receive) — converged-empty.
    expect(await network['b'].entryCount(channelId, streamId), equals(0));
    expect(
      await network.hasConverged(channelId, streamId, nodes: ['a', 'b']),
      isTrue,
    );

    // A writes a new entry; it must reach B contiguously from the
    // adopted floor (sequence 4, right after the floor at 3).
    await network['a'].write(channelId, streamId, [4]);
    await network.runRounds(10);

    expect(
      await network.hasConverged(channelId, streamId, nodes: ['a', 'b']),
      isTrue,
    );
    final bEntries = await network['b'].entries(channelId, streamId);
    expect(bEntries.map((e) => e.sequence).toList(), equals([4]));
  });
}
