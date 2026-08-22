import 'dart:math';

import 'package:test/test.dart';
import 'package:gossip/src/domain/aggregates/peer_registry.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/membership/domain/events/membership_events.dart';
import 'package:gossip/src/sync/infrastructure/membership_peer_directory.dart';

/// Contract tests for the sync↔membership ACL: [MembershipPeerDirectory]
/// must be a faithful, no-mocks wrapper over a real [PeerRegistry] — every
/// assertion here drives a real registry and observes either the
/// directory's mapped output or the registry's own post-call state.
void main() {
  group('MembershipPeerDirectory', () {
    late NodeId localNode;
    late PeerRegistry registry;
    late MembershipPeerDirectory directory;

    setUp(() {
      localNode = NodeId('local');
      registry = PeerRegistry(localNode: localNode);
      directory = MembershipPeerDirectory(registry);
    });

    group(
      'reachablePartners (contract clause 1: mirrors registry.reachablePeers)',
      () {
        test('ids match the registry\'s reachable peers exactly', () {
          final a = NodeId('peer-a');
          final b = NodeId('peer-b');
          registry.addPeer(a, occurredAt: DateTime.now());
          registry.addPeer(b, occurredAt: DateTime.now());

          final partnerIds = directory
              .reachablePartners()
              .map((p) => p.nodeId)
              .toSet();
          final registryIds = registry.reachablePeers.map((p) => p.id).toSet();

          expect(partnerIds, equals(registryIds));
        });

        test('excludes unreachable peers, same as the registry', () {
          final a = NodeId('peer-a');
          registry.addPeer(a, occurredAt: DateTime.now());
          registry.updatePeerStatus(
            a,
            PeerStatus.unreachable,
            occurredAt: DateTime.now(),
          );

          expect(directory.reachablePartners(), isEmpty);
          expect(registry.reachablePeers, isEmpty);
        });

        test('smoothedRtt is null before any RTT sample is recorded', () {
          final a = NodeId('peer-a');
          registry.addPeer(a, occurredAt: DateTime.now());

          expect(directory.reachablePartners().single.smoothedRtt, isNull);
        });

        test('smoothedRtt is mapped from peer.metrics.rttEstimate.smoothedRtt '
            'once a sample exists', () {
          final a = NodeId('peer-a');
          registry.addPeer(a, occurredAt: DateTime.now());
          registry.recordPeerRtt(a, const Duration(milliseconds: 42));

          expect(
            directory.reachablePartners().single.smoothedRtt,
            equals(const Duration(milliseconds: 42)),
          );
        });

        test('lastAntiEntropyMs is null until anti-entropy is recorded', () {
          final a = NodeId('peer-a');
          registry.addPeer(a, occurredAt: DateTime.now());

          expect(
            directory.reachablePartners().single.lastAntiEntropyMs,
            isNull,
          );
        });

        test('lastAntiEntropyMs is mapped from the peer once recorded', () {
          final a = NodeId('peer-a');
          registry.addPeer(a, occurredAt: DateTime.now());
          registry.updatePeerAntiEntropy(a, 12345);

          expect(
            directory.reachablePartners().single.lastAntiEntropyMs,
            equals(12345),
          );
        });
      },
    );

    group(
      'record* forwarding (contract clause 2: observable via registry state)',
      () {
        test('recordContact forwards to registry.updatePeerContact', () {
          final a = NodeId('peer-a');
          registry.addPeer(a, occurredAt: DateTime.now());

          directory.recordContact(a, 999);

          expect(registry.getPeer(a)!.lastContactMs, equals(999));
        });

        test(
          'recordAntiEntropy forwards to registry.updatePeerAntiEntropy',
          () {
            final a = NodeId('peer-a');
            registry.addPeer(a, occurredAt: DateTime.now());

            directory.recordAntiEntropy(a, 555);

            expect(registry.getPeer(a)!.lastAntiEntropyMs, equals(555));
          },
        );

        test(
          'recordMessageReceived forwards to registry.recordMessageReceived',
          () {
            final a = NodeId('peer-a');
            registry.addPeer(a, occurredAt: DateTime.now());

            directory.recordMessageReceived(a, 128, 1000, 10000);

            expect(registry.getPeer(a)!.metrics.bytesReceived, equals(128));
          },
        );

        test('recordMessageSent forwards to registry.recordMessageSent', () {
          final a = NodeId('peer-a');
          registry.addPeer(a, occurredAt: DateTime.now());

          directory.recordMessageSent(a, 64);

          expect(registry.getPeer(a)!.metrics.bytesSent, equals(64));
        });
      },
    );

    group(
      'selectRandomPartner (contract clause 3: registry-consistent selection)',
      () {
        test('returns null when no reachable peers exist', () {
          expect(directory.selectRandomPartner(Random(1)), isNull);
        });

        test('returns the same peer the registry would select for an '
            'identically-seeded Random', () {
          final a = NodeId('peer-a');
          registry.addPeer(a, occurredAt: DateTime.now());

          final expected = registry.selectRandomReachablePeer(Random(7));
          final actual = directory.selectRandomPartner(Random(7));

          expect(actual, isNotNull);
          expect(actual!.nodeId, equals(expected!.id));
        });

        test('selection is registry-consistent across many seeds (no '
            'reimplemented semantics)', () {
          final a = NodeId('peer-a');
          final b = NodeId('peer-b');
          registry.addPeer(a, occurredAt: DateTime.now());
          registry.addPeer(b, occurredAt: DateTime.now());

          for (var seed = 0; seed < 50; seed++) {
            final expected = registry.selectRandomReachablePeer(Random(seed));
            final actual = directory.selectRandomPartner(Random(seed));
            expect(actual!.nodeId, equals(expected!.id));
          }
        });
      },
    );
  });
}
