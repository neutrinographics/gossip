// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart' as gossip;
import 'package:gossip_bluey/gossip_bluey.dart';
import 'package:gossip_chat/presentation/controllers/chat_controller.dart';
import 'package:gossip_chat/presentation/view_models/discovered_peer.dart';

void main() {
  final addr = BleAddress('AA:BB:CC:DD:EE:FF');
  final addr2 = BleAddress('11:22:33:44:55:66');
  final nodeId = gossip.NodeId('00000000-0000-0000-0000-000000000001');
  final nodeId2 = gossip.NodeId('00000000-0000-0000-0000-000000000002');
  final t0 = DateTime.utc(2026, 6, 3, 12);
  final t1 = DateTime.utc(2026, 6, 3, 12, 0, 5);

  group('mergeCandidate', () {
    test('emits a discovered entry keyed by BleAddress when none exists', () {
      final peers = <Object, DiscoveredPeer>{};
      mergeCandidate(
        peers,
        ScanCandidate(
          address: addr,
          displayName: 'Pixel 6a',
          rssi: -55,
          lastSeen: t0,
        ),
      );
      expect(peers, hasLength(1));
      final p = peers[addr]!;
      expect(p.address, addr);
      expect(p.nodeId, isNull);
      expect(p.status, DiscoveredPeerStatus.discovered);
      expect(p.displayName, 'Pixel 6a');
      expect(p.rssi, -55);
      expect(p.lastSeenAt, t0);
      expect(p.everConnected, isFalse);
    });

    test('subsequent emission for same address updates rssi/lastSeen and '
        'preserves nodeId/status/everConnected', () {
      final peers = <Object, DiscoveredPeer>{
        nodeId: DiscoveredPeer(
          address: addr,
          nodeId: nodeId,
          displayName: 'Pixel 6a',
          rssi: -55,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.connected,
          everConnected: true,
        ),
      };
      mergeCandidate(
        peers,
        ScanCandidate(
          address: addr,
          displayName: 'Pixel 6a',
          rssi: -70,
          lastSeen: t1,
        ),
      );
      expect(peers, hasLength(1));
      final p = peers[nodeId]!;
      expect(p.rssi, -70);
      expect(p.lastSeenAt, t1);
      expect(p.status, DiscoveredPeerStatus.connected);
      expect(p.everConnected, isTrue);
    });

    test('updates the existing entry keyed by BleAddress', () {
      final peers = <Object, DiscoveredPeer>{
        addr: DiscoveredPeer(
          address: addr,
          rssi: -55,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.discovered,
        ),
      };
      mergeCandidate(
        peers,
        ScanCandidate(address: addr, rssi: -42, lastSeen: t1),
      );
      expect(peers, hasLength(1));
      expect(peers[addr]!.rssi, -42);
      expect(peers[addr]!.lastSeenAt, t1);
    });
  });

  group('mergePeerOpened', () {
    test('rekeys a connecting entry from BleAddress to NodeId, sets '
        'connected + everConnected', () {
      final peers = <Object, DiscoveredPeer>{
        addr: DiscoveredPeer(
          address: addr,
          rssi: -55,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.connecting,
        ),
      };
      mergePeerOpened(
        peers,
        nodeId,
        displayName: 'Pixel 6a',
        addressHint: addr,
        now: t1,
      );
      expect(peers.containsKey(addr), isFalse);
      expect(peers, hasLength(1));
      final p = peers[nodeId]!;
      expect(p.address, addr);
      expect(p.nodeId, nodeId);
      expect(p.displayName, 'Pixel 6a');
      expect(p.status, DiscoveredPeerStatus.connected);
      expect(p.everConnected, isTrue);
      expect(p.lastSeenAt, t1);
    });

    test('inserts a fresh NodeId-keyed entry when no prior entry exists', () {
      final peers = <Object, DiscoveredPeer>{};
      mergePeerOpened(
        peers,
        nodeId,
        displayName: 'Pixel 6a',
        now: t1,
      );
      expect(peers, hasLength(1));
      final p = peers[nodeId]!;
      expect(p.nodeId, nodeId);
      expect(p.status, DiscoveredPeerStatus.connected);
      expect(p.everConnected, isTrue);
    });

    test('updates an existing NodeId-keyed entry to connected/everConnected', () {
      final peers = <Object, DiscoveredPeer>{
        nodeId: DiscoveredPeer(
          address: addr,
          nodeId: nodeId,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.unreachable,
          everConnected: true,
        ),
      };
      mergePeerOpened(peers, nodeId, now: t1);
      final p = peers[nodeId]!;
      expect(p.status, DiscoveredPeerStatus.connected);
      expect(p.everConnected, isTrue);
      expect(p.lastSeenAt, t1);
    });

    test('falls back to a single in-flight connecting entry when no '
        'addressHint is supplied', () {
      final peers = <Object, DiscoveredPeer>{
        addr: DiscoveredPeer(
          address: addr,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.connecting,
        ),
      };
      mergePeerOpened(peers, nodeId, now: t1);
      expect(peers.containsKey(addr), isFalse);
      expect(peers[nodeId]!.nodeId, nodeId);
      expect(peers[nodeId]!.status, DiscoveredPeerStatus.connected);
    });
  });

  group('mergePeerClosed', () {
    test('transitions a connected entry to unreachable and keeps everConnected', () {
      final peers = <Object, DiscoveredPeer>{
        nodeId: DiscoveredPeer(
          address: addr,
          nodeId: nodeId,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.connected,
          everConnected: true,
        ),
      };
      mergePeerClosed(peers, nodeId);
      expect(peers, hasLength(1));
      final p = peers[nodeId]!;
      expect(p.status, DiscoveredPeerStatus.unreachable);
      expect(p.everConnected, isTrue);
    });

    test('no-ops if peer not in map', () {
      final peers = <Object, DiscoveredPeer>{};
      mergePeerClosed(peers, nodeId);
      expect(peers, isEmpty);
    });
  });

  group('mergeGossipPeerStatus', () {
    test('reachable -> connected', () {
      final peers = <Object, DiscoveredPeer>{
        nodeId: DiscoveredPeer(
          address: addr,
          nodeId: nodeId,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.suspected,
          everConnected: true,
        ),
      };
      mergeGossipPeerStatus(peers, nodeId, gossip.PeerStatus.reachable);
      expect(peers[nodeId]!.status, DiscoveredPeerStatus.connected);
    });

    test('suspected -> suspected', () {
      final peers = <Object, DiscoveredPeer>{
        nodeId: DiscoveredPeer(
          address: addr,
          nodeId: nodeId,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.connected,
          everConnected: true,
        ),
      };
      mergeGossipPeerStatus(peers, nodeId, gossip.PeerStatus.suspected);
      expect(peers[nodeId]!.status, DiscoveredPeerStatus.suspected);
    });

    test('unreachable -> unreachable', () {
      final peers = <Object, DiscoveredPeer>{
        nodeId: DiscoveredPeer(
          address: addr,
          nodeId: nodeId,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.connected,
          everConnected: true,
        ),
      };
      mergeGossipPeerStatus(peers, nodeId, gossip.PeerStatus.unreachable);
      expect(peers[nodeId]!.status, DiscoveredPeerStatus.unreachable);
    });

    test('no-ops if peer not in map (does not surprise the user with '
        'a "connected" pill on a discovered-but-not-yet-connected row)', () {
      final peers = <Object, DiscoveredPeer>{
        addr: DiscoveredPeer(
          address: addr,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.discovered,
        ),
      };
      mergeGossipPeerStatus(peers, nodeId, gossip.PeerStatus.reachable);
      // BleAddress-keyed entry is untouched.
      expect(peers[addr]!.status, DiscoveredPeerStatus.discovered);
      expect(peers.containsKey(nodeId), isFalse);
    });
  });

  group('pruneUnconnected (prune-on-stop)', () {
    test('drops discovered-only entries; keeps ever-connected entries', () {
      final peers = <Object, DiscoveredPeer>{
        addr: DiscoveredPeer(
          address: addr,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.discovered,
        ),
        addr2: DiscoveredPeer(
          address: addr2,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.failed,
        ),
        nodeId: DiscoveredPeer(
          address: BleAddress('99:88:77:66:55:44'),
          nodeId: nodeId,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.unreachable,
          everConnected: true,
        ),
        nodeId2: DiscoveredPeer(
          address: BleAddress('AB:CD:EF:01:02:03'),
          nodeId: nodeId2,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.connected,
          everConnected: true,
        ),
      };
      pruneUnconnected(peers);
      expect(peers.containsKey(addr), isFalse);
      expect(peers.containsKey(addr2), isFalse);
      expect(peers.containsKey(nodeId), isTrue);
      expect(peers.containsKey(nodeId2), isTrue);
    });

    test('drops nothing when all entries are everConnected', () {
      final peers = <Object, DiscoveredPeer>{
        nodeId: DiscoveredPeer(
          address: addr,
          nodeId: nodeId,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.unreachable,
          everConnected: true,
        ),
      };
      pruneUnconnected(peers);
      expect(peers, hasLength(1));
    });

    test('clears the whole map when nothing has ever connected', () {
      final peers = <Object, DiscoveredPeer>{
        addr: DiscoveredPeer(
          address: addr,
          lastSeenAt: t0,
          status: DiscoveredPeerStatus.discovered,
        ),
      };
      pruneUnconnected(peers);
      expect(peers, isEmpty);
    });
  });
}
