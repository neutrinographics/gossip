import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/application/observability/bluey_metrics.dart';
import 'package:gossip_bluey/src/application/services/connection_manager.dart';
import 'package:gossip_bluey/src/domain/aggregates/connection_registry.dart';
import 'package:gossip_bluey/src/domain/events/connection_event.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';
import 'package:gossip_bluey/src/domain/value_objects/ble_address.dart';

import '../../fakes/fake_bluey_port.dart';

// The tie-break rule: the surviving link is the one whose CENTRAL is the
// lexicographically smaller NodeId. 'aaa' < 'zzz', so:
//   local 'aaa' vs remote 'zzz'  → local wins  → local must be central.
//   local 'zzz' vs remote 'aaa'  → local loses → local must be peripheral.
void main() {
  late FakeBlueyNetwork network;

  setUp(() {
    network = FakeBlueyNetwork();
  });

  (ConnectionManager, FakeBlueyPort, ConnectionRegistry, List<ConnectionEvent>)
      makeManager(String localId) {
    final port = FakeBlueyPort(localNodeId: NodeId(localId), network: network);
    final registry = ConnectionRegistry();
    final manager = ConnectionManager(
      port: port,
      registry: registry,
      metrics: BlueyMetrics(),
      localNodeId: NodeId(localId),
    );
    final events = <ConnectionEvent>[];
    manager.events.listen(events.add);
    return (manager, port, registry, events);
  }

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  group('mutual-connect tie-break', () {
    test('case 1: registered central survives when local wins; '
        'inbound peripheral is declined', () async {
      final (_, port, registry, events) = makeManager('aaa');
      final remote = NodeId('zzz');

      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();
      expect(registry.get(remote)!.role, ConnectionRole.central);

      port.emitPeerConnected(remote, ConnectionRole.peripheral,
          address: const BleAddress('addr-1'));
      await pump();

      expect(registry.get(remote)!.role, ConnectionRole.central,
          reason: 'winning central registration must be untouched');
      expect(
        port.disconnectRoleCalls,
        contains((remote, ConnectionRole.peripheral)),
        reason: 'the losing peripheral is declined (remote closes it '
            'physically from its end — it is the remote\'s central)',
      );
      expect(events.whereType<PeerClosed>(), isEmpty,
          reason: 'NodeId-level connectivity never flapped');
    });

    test('case 2: registered central is closed and replaced when local '
        'loses; peripheral becomes the active handle', () async {
      final (_, port, registry, events) = makeManager('zzz');
      final remote = NodeId('aaa');

      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();

      port.emitPeerConnected(remote, ConnectionRole.peripheral,
          address: const BleAddress('addr-1'));
      await pump();

      expect(registry.get(remote)!.role, ConnectionRole.peripheral,
          reason: 'we lost: the link where the remote (smaller id) is '
              'central must survive — that is our peripheral link');
      expect(
        port.disconnectRoleCalls,
        contains((remote, ConnectionRole.central)),
        reason: 'we must close our own redundant central',
      );
      expect(events.whereType<PeerClosed>(), isEmpty);
      expect(events.whereType<PeerOpened>(), hasLength(1),
          reason: 'no PeerOpened re-emission on swap');
    });

    test('case 3: registered peripheral is replaced by late-completing '
        'central when local wins', () async {
      final (_, port, registry, events) = makeManager('aaa');
      final remote = NodeId('zzz');

      port.emitPeerConnected(remote, ConnectionRole.peripheral,
          address: const BleAddress('addr-1'));
      await pump();

      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();

      expect(registry.get(remote)!.role, ConnectionRole.central);
      expect(
        port.disconnectRoleCalls,
        contains((remote, ConnectionRole.peripheral)),
        reason: 'the stale peripheral is marked rejected so its inbound '
            'stops flowing (remote physically closes it)',
      );
      expect(events.whereType<PeerClosed>(), isEmpty);
    });

    test('case 4: late-completing central is closed immediately when '
        'local loses; peripheral registration untouched', () async {
      final (_, port, registry, events) = makeManager('zzz');
      final remote = NodeId('aaa');

      port.emitPeerConnected(remote, ConnectionRole.peripheral,
          address: const BleAddress('addr-1'));
      await pump();
      final peripheralHandle = registry.get(remote);

      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();

      expect(identical(registry.get(remote), peripheralHandle), isTrue,
          reason: 'surviving registration must be the SAME handle object');
      expect(
        port.disconnectRoleCalls,
        contains((remote, ConnectionRole.central)),
      );
      expect(events.whereType<PeerClosed>(), isEmpty);
    });

    test('a disconnect event for the closed loser link does not '
        'unregister the surviving link', () async {
      final (_, port, registry, _) = makeManager('zzz');
      final remote = NodeId('aaa');

      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();
      port.emitPeerConnected(remote, ConnectionRole.peripheral,
          address: const BleAddress('addr-1'));
      await pump();

      // The physical close of our central eventually surfaces as a
      // disconnect event for the CENTRAL role. The registered handle is
      // now peripheral, so the existing role guard must ignore it.
      port.emitPeerDisconnected(remote, ConnectionRole.central, 'closed');
      await pump();

      expect(registry.contains(remote), isTrue);
      expect(registry.get(remote)!.role, ConnectionRole.peripheral);
    });

    test('same-role duplicate keeps today\'s drop-the-newcomer behavior',
        () async {
      final (_, port, registry, _) = makeManager('aaa');
      final remote = NodeId('zzz');

      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-1'));
      await pump();
      final first = registry.get(remote);

      port.emitPeerConnected(remote, ConnectionRole.central,
          address: const BleAddress('addr-2'));
      await pump();

      expect(identical(registry.get(remote), first), isTrue);
      expect(
        port.disconnectRoleCalls,
        contains((remote, ConnectionRole.central)),
      );
    });
  });
}
