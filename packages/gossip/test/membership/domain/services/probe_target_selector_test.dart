import 'dart:math';

import 'package:gossip/src/membership/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/membership/domain/entities/peer.dart';
import 'package:gossip/src/membership/domain/services/probe_target_selector.dart';
import 'package:gossip/src/membership/domain/value_objects/peer_status.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:test/test.dart';

/// Transplanted from failure_detector_probe_selection_test.dart (H3),
/// failure_detector_suppression_test.dart (WIRE4-3), and the probing-hold
/// group of failure_detector_test.dart (CC5-2/CC5-14 detector slice):
/// these pin the same round-robin/suppression/hold semantics the detector
/// relied on before the extraction, now against [ProbeTargetSelector]
/// directly.
void main() {
  late NodeId localNode;
  late PeerRegistry peerRegistry;
  late InMemoryTimePort timePort;

  NodeId addPeer(String name, {PeerStatus? status}) {
    final id = NodeId(name);
    peerRegistry.addPeer(id, occurredAt: DateTime.now());
    if (status != null) {
      // Route through suspected first so unreachable is a legal transition.
      if (status == PeerStatus.suspected || status == PeerStatus.unreachable) {
        peerRegistry.updatePeerStatus(
          id,
          PeerStatus.suspected,
          occurredAt: DateTime.now(),
        );
      }
      if (status == PeerStatus.unreachable) {
        peerRegistry.updatePeerStatus(
          id,
          PeerStatus.unreachable,
          occurredAt: DateTime.now(),
        );
      }
    }
    return id;
  }

  setUp(() {
    localNode = NodeId('local');
    peerRegistry = PeerRegistry(localNode: localNode);
    timePort = InMemoryTimePort();
    // A never-contacted/never-probed peer's suppression-cap clock anchors
    // at epoch 0; starting the fake clock well past zero keeps "never
    // probed" reading as immediately cap-expired (cold-start expectation)
    // rather than accidentally coinciding with a fresh clock read of 0.
    timePort.advance(const Duration(minutes: 1));
  });

  group('ProbeTargetSelector.nextProbeTarget round-robin (H3)', () {
    test('every block of n selections covers all probable peers exactly '
        'once, then reshuffles', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(1234),
      );
      const n = 5;
      final ids = {for (var i = 0; i < n; i++) addPeer('peer$i')};

      for (var cycle = 0; cycle < 4; cycle++) {
        final block = [
          for (var i = 0; i < n; i++)
            selector.nextProbeTarget(freshnessWindow: Duration.zero)!.id,
        ];
        expect(
          block.toSet(),
          equals(ids),
          reason: 'cycle $cycle must cover every probable peer exactly once',
        );
      }
    });

    test('a specific peer is always selected within n rounds (bounded '
        'worst-case coverage)', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(7),
      );
      const n = 6;
      final ids = [for (var i = 0; i < n; i++) addPeer('peer$i')];
      final target = ids[3];

      for (var start = 0; start < 3; start++) {
        final window = <NodeId>[];
        for (var i = 0; i < n; i++) {
          window.add(
            selector.nextProbeTarget(freshnessWindow: Duration.zero)!.id,
          );
        }
        expect(
          window,
          contains(target),
          reason: 'window $start must include the target within n rounds',
        );
      }
    });

    test('returns null when there are no probable peers', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(),
      );
      expect(selector.nextProbeTarget(freshnessWindow: Duration.zero), isNull);
    });

    test('ids no longer probable are skipped by the cursor', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(3),
      );
      final ids = [for (var i = 0; i < 4; i++) addPeer('peer$i')];

      // Prime a cycle so the cursor holds a shuffled order.
      selector.nextProbeTarget(freshnessWindow: Duration.zero);

      // Under seed 3, the shuffle is [peer1, peer0, peer2, peer3] and the
      // priming call above already consumed peer1 — so the cursor now
      // sits on peer0 (ids[0]). It must be *that* id — not just any id —
      // that goes unreachable: only the id actually under the cursor
      // exercises the skip-and-advance branch below; marking an
      // already-consumed or not-yet-reached id unreachable would let this
      // assertion pass on the eligibility filter alone, never touching the
      // cursor-skip loop.
      peerRegistry.updatePeerStatus(
        ids[0],
        PeerStatus.suspected,
        occurredAt: DateTime.now(),
      );
      peerRegistry.updatePeerStatus(
        ids[0],
        PeerStatus.unreachable,
        occurredAt: DateTime.now(),
      );

      final selected = <NodeId>[];
      for (var i = 0; i < 3; i++) {
        selected.add(
          selector.nextProbeTarget(freshnessWindow: Duration.zero)!.id,
        );
      }
      expect(selected, isNot(contains(ids[0])));
    });
  });

  group('ProbeTargetSelector.nextProbeTarget probing hold', () {
    test('a peer under a probing hold is never selected', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(99),
      );
      final ids = [for (var i = 0; i < 4; i++) addPeer('peer$i')];
      selector.setProbingHold(ids[2], timePort.nowMs + 100000);

      final selected = <NodeId>[];
      for (var i = 0; i < 12; i++) {
        final peer = selector.nextProbeTarget(freshnessWindow: Duration.zero);
        if (peer != null) selected.add(peer.id);
      }

      expect(selected, isNot(contains(ids[2])));
      expect(selected.toSet(), equals({ids[0], ids[1], ids[3]}));
    });

    test('clearProbingHold makes the peer immediately selectable again', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(5),
      );
      final id = addPeer('peer1');
      selector.setProbingHold(id, timePort.nowMs + 100000);
      expect(selector.nextProbeTarget(freshnessWindow: Duration.zero), isNull);

      selector.clearProbingHold(id);
      final selected = selector.nextProbeTarget(freshnessWindow: Duration.zero);
      expect(selected, isNotNull);
      expect(selected!.id, equals(id));
    });

    test('hasProbingHold reflects an active hold and its expiry', () async {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(),
      );
      final id = addPeer('peer1');
      expect(selector.hasProbingHold(id), isFalse);

      selector.setProbingHold(id, timePort.nowMs + 100);
      expect(selector.hasProbingHold(id), isTrue);

      await timePort.advance(const Duration(milliseconds: 101));
      expect(selector.hasProbingHold(id), isFalse);
    });

    test('forgetPeer drops the hold and probe-attempt bookkeeping', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(),
      );
      final id = addPeer('peer1');
      selector.setProbingHold(id, timePort.nowMs + 100000);
      selector.recordProbeAttempt(id, timePort.nowMs);

      selector.forgetPeer(id);

      expect(selector.hasProbingHold(id), isFalse);
      // With the hold gone and the probe-attempt history forgotten, the
      // peer is immediately probe-eligible again (missing entry reads as
      // "never probed").
      final selected = selector.nextProbeTarget(freshnessWindow: Duration.zero);
      expect(selected!.id, equals(id));
    });
  });

  group('ProbeTargetSelector.nextProbeTarget freshness suppression '
      '(WIRE4-3)', () {
    test('a peer heard from within the interval is not selected', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(),
      );
      final fresh = addPeer('fresh');
      final stale = addPeer('stale');
      peerRegistry.updatePeerContact(fresh, timePort.nowMs);
      // stale's lastContactMs stays 0 (never heard from).

      for (var i = 0; i < 4; i++) {
        expect(
          selector
              .nextProbeTarget(freshnessWindow: const Duration(seconds: 30))!
              .id,
          stale,
          reason: 'only the stale peer needs a probe',
        );
      }
    });

    test('when every peer is fresh, selection returns null', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(),
      );
      final a = addPeer('a');
      final b = addPeer('b');
      peerRegistry.updatePeerContact(a, timePort.nowMs);
      peerRegistry.updatePeerContact(b, timePort.nowMs);

      expect(
        selector.nextProbeTarget(freshnessWindow: const Duration(seconds: 30)),
        isNull,
      );
    });

    test('the suppression cap re-enables a fresh-but-never-probed peer after '
        '2 minutes', () async {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(),
      );
      final peer = addPeer('peer');

      // A never-probed peer's cap anchors at epoch 0 while the clock
      // starts at t=60s, so the cap expires at absolute t=120s.
      for (var i = 0; i < 2; i++) {
        peerRegistry.updatePeerContact(peer, timePort.nowMs);
        expect(
          selector.nextProbeTarget(
            freshnessWindow: const Duration(seconds: 30),
          ),
          isNull,
          reason: 'still within the cap window — suppression holds',
        );
        await timePort.advance(const Duration(seconds: 30));
      }

      // Reach absolute t=120s while the peer keeps looking freshly
      // contacted (simulating one-way loss: our probes to it die, but
      // its own traffic keeps refreshing lastContactMs).
      Peer? selected;
      for (var i = 0; i < 3 && selected == null; i++) {
        peerRegistry.updatePeerContact(peer, timePort.nowMs);
        selected = selector.nextProbeTarget(
          freshnessWindow: const Duration(seconds: 30),
        );
        await timePort.advance(const Duration(seconds: 30));
      }

      expect(
        selected,
        isNotNull,
        reason:
            'the cap must force an actual probe within 2 minutes despite '
            'continuous freshness, or one-way loss to this peer would '
            'never be detected',
      );
      expect(selected!.id, equals(peer));
    });

    test('recordProbeAttempt resets the suppression-cap clock, so freshness '
        'alone suppresses again immediately after', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(),
      );
      final peer = addPeer('peer');
      peerRegistry.updatePeerContact(peer, timePort.nowMs);
      selector.recordProbeAttempt(peer, timePort.nowMs);

      expect(
        selector.nextProbeTarget(freshnessWindow: const Duration(seconds: 30)),
        isNull,
        reason: 'a just-recorded probe attempt resets the cap window',
      );
    });
  });

  group('ProbeTargetSelector.selectIntermediaries', () {
    test('excludes the target and returns up to count reachable peers', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(11),
      );
      final target = addPeer('target');
      final others = {for (var i = 0; i < 5; i++) addPeer('other$i')};

      final selected = selector.selectIntermediaries(target, 3);

      expect(selected, hasLength(3));
      expect(selected.map((p) => p.id), isNot(contains(target)));
      expect(others, containsAll(selected.map((p) => p.id)));
      // No duplicates.
      expect(selected.map((p) => p.id).toSet(), hasLength(3));
    });

    test('returns fewer than count when not enough candidates exist', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(),
      );
      final target = addPeer('target');
      addPeer('other0');

      final selected = selector.selectIntermediaries(target, 3);

      expect(selected, hasLength(1));
    });

    test('returns empty when no candidates exist', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(),
      );
      final target = addPeer('target');

      expect(selector.selectIntermediaries(target, 3), isEmpty);
    });
  });

  group('ProbeTargetSelector.nextUnreachableTarget', () {
    test('round-robins over unreachable peers', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(),
      );
      final a = addPeer('a', status: PeerStatus.unreachable);
      final b = addPeer('b', status: PeerStatus.unreachable);

      final first = selector.nextUnreachableTarget()!.id;
      final second = selector.nextUnreachableTarget()!.id;
      final third = selector.nextUnreachableTarget()!.id;

      expect({first, second}, equals({a, b}));
      expect(third, equals(first), reason: 'the cursor wraps after n picks');
    });

    test('wraps the cursor when membership shrinks between calls', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(),
      );
      addPeer('a', status: PeerStatus.unreachable);
      final b = addPeer('b', status: PeerStatus.unreachable);
      final c = addPeer('c', status: PeerStatus.unreachable);

      // Advance the cursor to index 2 (pointing at 'c').
      selector.nextUnreachableTarget();
      selector.nextUnreachableTarget();

      // 'a' becomes reachable again — only b, c remain unreachable, so the
      // stale index-2 cursor must wrap into range rather than throwing.
      peerRegistry.updatePeerContact(NodeId('a'), timePort.nowMs);

      final selected = selector.nextUnreachableTarget();
      expect(selected, isNotNull);
      expect({b, c}, contains(selected!.id));
    });

    test('returns null when there are no unreachable peers', () {
      final selector = ProbeTargetSelector(
        peerRegistry: peerRegistry,
        timePort: timePort,
        random: Random(),
      );
      expect(selector.nextUnreachableTarget(), isNull);
    });
  });
}
