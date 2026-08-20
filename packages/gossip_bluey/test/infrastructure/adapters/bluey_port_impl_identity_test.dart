import 'dart:async';
import 'dart:typed_data';

import 'package:bluey/bluey.dart' as bluey;
import 'package:bluey_platform_interface/bluey_platform_interface.dart'
    show PlatformKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/interfaces/bluey_port.dart';
import 'package:gossip_bluey/src/domain/value_objects/gossip_characteristic_uuids.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';
import 'package:gossip_bluey/src/infrastructure/adapters/bluey_port_impl.dart';
import 'package:mocktail/mocktail.dart';

class _MockBluey extends Mock implements bluey.Bluey {}

class _MockServer extends Mock implements bluey.Server {}

class _MockBlueyPeer extends Mock implements bluey.BlueyPeer {}

class _MockPeerConnection extends Mock implements bluey.PeerConnection {}

class _MockConnection extends Mock implements bluey.Connection {}

class _MockRemoteService extends Mock implements bluey.RemoteService {}

class _MockRemoteCharacteristic extends Mock
    implements bluey.RemoteCharacteristic {}

class _MockClient extends Mock implements bluey.Client {}

class _MockCapabilities extends Mock implements bluey.Capabilities {}

/// Full harness around BlueyPortImpl with a mocked bluey layer:
/// controllable server streams (peerConnections / disconnections /
/// writeRequests) and per-peer mock central connections.
class _Harness {
  _Harness._();

  final mockBluey = _MockBluey();
  final server = _MockServer();
  final stateCtrl = StreamController<bluey.BluetoothState>.broadcast();
  final peerConnections = StreamController<bluey.PeerClient>.broadcast();
  final disconnections = StreamController<bluey.ClientAddress>.broadcast();
  final writeRequests = StreamController<bluey.WriteRequest>.broadcast();
  final advertisingStateChanges =
      StreamController<bluey.AdvertisingState>.broadcast();

  late final BlueyPortImpl port;
  final events = <BlueyPortEvent>[];
  late final StreamSubscription<BlueyPortEvent> _eventSub;
  LogCallback? _onLog;

  static final localId = NodeId('11111111-1111-1111-1111-111111111111');
  static final serviceUuid = ServiceUuid(
    'f0000000-0000-0000-0000-000000000000',
  );
  static String get dataCharUuid =>
      GossipCharacteristicUuids.derive(serviceUuid).dataCharacteristic;

  static Future<_Harness> create({LogCallback? onLog}) async {
    final h = _Harness._();
    h._onLog = onLog;
    final caps = _MockCapabilities();
    when(() => caps.platformKind).thenReturn(PlatformKind.android);
    when(() => h.mockBluey.capabilities).thenReturn(caps);
    when(() => h.mockBluey.currentState).thenReturn(bluey.BluetoothState.on);
    when(() => h.mockBluey.stateStream).thenAnswer((_) => h.stateCtrl.stream);
    when(() => h.mockBluey.server()).thenReturn(h.server);

    when(() => h.server.advertisingState)
        .thenReturn(bluey.AdvertisingState.idle);
    when(() => h.server.advertisingStateChanges)
        .thenAnswer((_) => h.advertisingStateChanges.stream);
    when(() => h.server.addService(any())).thenAnswer((_) async {});
    when(
      () => h.server.startAdvertising(
        name: any(named: 'name'),
        services: any(named: 'services'),
        peerDiscoverable: any(named: 'peerDiscoverable'),
      ),
    ).thenAnswer((_) async {});
    when(() => h.server.peerConnections)
        .thenAnswer((_) => h.peerConnections.stream);
    when(() => h.server.disconnections)
        .thenAnswer((_) => h.disconnections.stream);
    when(() => h.server.writeRequests)
        .thenAnswer((_) => h.writeRequests.stream);
    when(() => h.server.stopAdvertising()).thenAnswer((_) async {});
    when(() => h.server.dispose()).thenAnswer((_) async {});

    h.port = await BlueyPortImpl.create(
      localNodeId: localId,
      blueyInstance: h.mockBluey,
      onLog: h._onLog,
    );
    h._eventSub = h.port.events.listen(h.events.add);
    await h.port.startAdvertising(
      serviceUuid: serviceUuid,
      displayName: 'Local',
      localNodeId: localId,
    );
    return h;
  }

  /// Builds a mock central connection for [target] whose gossip service
  /// tree resolves correctly. Returns the pieces so tests can drive
  /// state changes and inspect calls.
  ({
    _MockPeerConnection peerConn,
    _MockConnection raw,
    _MockRemoteCharacteristic dataChar,
    StreamController<bluey.ConnectionState> stateChanges,
    StreamController<Uint8List> notifications,
  })
  buildCentral(NodeId target, {Object? servicesError}) {
    final peerConn = _MockPeerConnection();
    final raw = _MockConnection();
    final service = _MockRemoteService();
    final dataChar = _MockRemoteCharacteristic();
    // Test-lifetime controllers; the harness dies with the test.
    // ignore: close_sinks
    final stateChanges = StreamController<bluey.ConnectionState>.broadcast();
    // ignore: close_sinks
    final notifications = StreamController<Uint8List>.broadcast();

    when(() => peerConn.serverId).thenReturn(bluey.ServerId(target.value));
    when(() => peerConn.connection).thenReturn(raw);
    when(() => peerConn.disconnect()).thenAnswer((_) async {});
    if (servicesError != null) {
      when(() => peerConn.services(cache: any(named: 'cache')))
          .thenThrow(servicesError);
      when(() => peerConn.services()).thenThrow(servicesError);
    } else {
      when(() => peerConn.services(cache: any(named: 'cache')))
          .thenAnswer((_) async => [service]);
      when(() => peerConn.services()).thenAnswer((_) async => [service]);
    }
    when(() => raw.maxWritePayload(withResponse: any(named: 'withResponse')))
        .thenAnswer((_) async => bluey.WritePayloadLimit(185));
    when(() => raw.stateChanges).thenAnswer((_) => stateChanges.stream);
    when(() => service.uuid).thenReturn(bluey.UUID(serviceUuid.value));
    when(() => service.characteristics()).thenReturn([dataChar]);
    when(() => dataChar.uuid).thenReturn(bluey.UUID(dataCharUuid));
    when(() => dataChar.notifications).thenAnswer((_) => notifications.stream);
    when(
      () => dataChar.write(any(), withResponse: any(named: 'withResponse')),
    ).thenAnswer((_) async {});

    final blueyPeer = _MockBlueyPeer();
    when(() => blueyPeer.connect()).thenAnswer((_) async => peerConn);
    when(() => mockBluey.peer(bluey.ServerId(target.value)))
        .thenReturn(blueyPeer);

    return (
      peerConn: peerConn,
      raw: raw,
      dataChar: dataChar,
      stateChanges: stateChanges,
      notifications: notifications,
    );
  }

  /// Builds a peripheral-role PeerClient for [nodeId] at [address].
  bluey.PeerClient buildPeripheral(NodeId nodeId, String address) {
    final client = _MockClient();
    when(() => client.address).thenReturn(bluey.ClientAddress(address));
    when(() => client.mtu).thenReturn(100);
    return bluey.PeerClient.create(
      client: client,
      serverId: bluey.ServerId(nodeId.value),
    );
  }

  bluey.WriteRequest writeFrom(String address, List<int> data) {
    final client = _MockClient();
    when(() => client.address).thenReturn(bluey.ClientAddress(address));
    return bluey.WriteRequest(
      client: client,
      characteristicId: bluey.UUID(dataCharUuid),
      value: Uint8List.fromList(data),
      offset: 0,
      responseNeeded: false,
      internalRequestId: 0,
    );
  }

  Future<void> flush([int n = 3]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> dispose() async {
    await _eventSub.cancel();
    await port.dispose();
    await stateCtrl.close();
    await peerConnections.close();
    await disconnections.close();
    await writeRequests.close();
    await advertisingStateChanges.close();
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(
      bluey.HostedService(
        uuid: bluey.UUID('00000000-0000-0000-0000-000000000000'),
        characteristics: const [],
      ),
    );
    registerFallbackValue(const <bluey.UUID>[]);
    registerFallbackValue(
      bluey.ServerId('99999999-9999-9999-9999-999999999999'),
    );
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(_MockClient());
    registerFallbackValue(bluey.UUID('00000000-0000-0000-0000-000000000000'));
  });

  final peerX = NodeId('22222222-2222-2222-2222-222222222222');

  group('H9: duplicate-reject must not black-hole inbound writes', () {
    test(
      'after disconnectRole(peripheral), writes from that client still '
      'resolve to the peer',
      () async {
        final h = await _Harness.create();

        // Inbound peripheral connection from X.
        h.peerConnections.add(h.buildPeripheral(peerX, 'addr-x'));
        await h.flush();
        expect(h.events.whereType<PortPeerConnected>(), hasLength(1));

        // What ConnectionManager does on a duplicate rejection. bluey has
        // no per-client disconnect, so the physical link STAYS UP.
        await h.port.disconnectRole(peerX, ConnectionRole.peripheral);
        h.events.clear();

        // X (whose registered link on the other side is central) keeps
        // sending gossip via GATT writes on this very link.
        h.writeRequests.add(h.writeFrom('addr-x', [1, 2, 3]));
        await h.flush();

        final data = h.events.whereType<PortPeerData>().toList();
        expect(
          data,
          hasLength(1),
          reason:
              'dropping the address→NodeId mapping while the link is up '
              'silently discards 100% of the peer\'s traffic forever',
        );
        expect(data.single.nodeId, equals(peerX));

        await h.dispose();
      },
    );
  });

  group('H10: stale disconnections must not kill a newer link', () {
    test(
      'a stale disconnect for the OLD client address leaves the '
      'reconnected client intact',
      () async {
        final h = await _Harness.create();

        // X connects at addr-1, drops, reconnects at addr-2 — but the
        // platform delivers the addr-1 disconnection AFTER the addr-2
        // connection (async event races).
        h.peerConnections.add(h.buildPeripheral(peerX, 'addr-1'));
        await h.flush();
        h.peerConnections.add(h.buildPeripheral(peerX, 'addr-2'));
        await h.flush();
        h.events.clear();

        h.disconnections.add(const bluey.ClientAddress('addr-1'));
        await h.flush();

        expect(
          h.events.whereType<PortPeerDisconnected>(),
          isEmpty,
          reason:
              'the stale addr-1 event must not unregister the live addr-2 '
              'client',
        );

        // The live client's writes still resolve.
        h.writeRequests.add(h.writeFrom('addr-2', [9]));
        await h.flush();
        expect(h.events.whereType<PortPeerData>(), hasLength(1));

        await h.dispose();
      },
    );
  });

  group('COR3-5: peripheral supersession must disconnect the old link', () {
    test(
      'a fast reconnect under a new address emits PortPeerDisconnected for '
      'the old link BEFORE PortPeerConnected for the new one',
      () async {
        final h = await _Harness.create();

        // X connects at addr-1, then fast-reconnects at addr-2 before the
        // platform delivers any disconnection for addr-1.
        h.peerConnections.add(h.buildPeripheral(peerX, 'addr-1'));
        await h.flush();
        h.events.clear();

        h.peerConnections.add(h.buildPeripheral(peerX, 'addr-2'));
        await h.flush();

        expect(
          h.events,
          hasLength(2),
          reason:
              'emitting only PortPeerConnected makes ConnectionManager '
              'duplicate-reject the LIVE replacement link',
        );
        final disconnected = h.events[0];
        expect(disconnected, isA<PortPeerDisconnected>());
        expect(
          (disconnected as PortPeerDisconnected).nodeId,
          equals(peerX),
        );
        expect(disconnected.role, equals(ConnectionRole.peripheral));
        expect(disconnected.reason, contains('superseded'));
        final connected = h.events[1];
        expect(connected, isA<PortPeerConnected>());
        expect(
          (connected as PortPeerConnected).role,
          equals(ConnectionRole.peripheral),
        );

        // The replacement link is live: its writes resolve to the peer.
        h.events.clear();
        h.writeRequests.add(h.writeFrom('addr-2', [1, 2, 3]));
        await h.flush();
        expect(h.events.whereType<PortPeerData>(), hasLength(1));

        await h.dispose();
      },
    );

    test(
      'a superseded link that was already rejected does not emit a second '
      'disconnect',
      () async {
        final h = await _Harness.create();

        h.peerConnections.add(h.buildPeripheral(peerX, 'addr-1'));
        await h.flush();
        // Duplicate rejection already reported this link as disconnected.
        await h.port.disconnectRole(peerX, ConnectionRole.peripheral);
        h.events.clear();

        h.peerConnections.add(h.buildPeripheral(peerX, 'addr-2'));
        await h.flush();

        expect(
          h.events.whereType<PortPeerDisconnected>(),
          isEmpty,
          reason: 'the rejected link was already reported as disconnected',
        );
        expect(h.events.whereType<PortPeerConnected>(), hasLength(1));

        await h.dispose();
      },
    );
  });

  group('H12: central registration rolls back on failure', () {
    test(
      'a failed service discovery leaves no stranded connection',
      () async {
        final h = await _Harness.create();
        final failing = h.buildCentral(
          peerX,
          servicesError: StateError('peer dropped mid-discovery'),
        );

        await expectLater(() => h.port.connect(peerX), throwsA(anything));
        await h.flush();

        expect(
          h.events.whereType<PortPeerConnected>(),
          isEmpty,
          reason: 'a failed registration must not announce a connection',
        );
        verify(() => failing.peerConn.disconnect()).called(1);

        // No dead handle left behind: sendData reports no connection.
        await expectLater(
          () => h.port.sendData(peerX, Uint8List.fromList([1])),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('no connection'),
            ),
          ),
        );

        // A retry with a healthy peer succeeds cleanly.
        h.buildCentral(peerX);
        await h.port.connect(peerX);
        await h.flush();
        expect(h.events.whereType<PortPeerConnected>(), hasLength(1));

        await h.dispose();
      },
    );
  });

  group('COR3-23: platform stream errors are logged, not left unhandled', () {
    test(
      'an error on the server peerConnections stream is logged and later '
      'connections still register',
      () async {
        final errorLogs = <String>[];
        final h = await _Harness.create(
          onLog: (level, msg, [e, st]) {
            if (level == LogLevel.error) errorLogs.add(msg);
          },
        );

        h.peerConnections.addError(StateError('platform hiccup'));
        await h.flush();
        expect(errorLogs, isNotEmpty);

        // The subscription survives: a real connection still lands.
        h.peerConnections.add(h.buildPeripheral(peerX, 'addr-x'));
        await h.flush();
        expect(h.events.whereType<PortPeerConnected>(), hasLength(1));

        await h.dispose();
      },
    );

    test(
      'an error on a central link\'s notifications stream is logged and '
      'does not tear the link down',
      () async {
        final errorLogs = <String>[];
        final h = await _Harness.create(
          onLog: (level, msg, [e, st]) {
            if (level == LogLevel.error) errorLogs.add(msg);
          },
        );
        final central = h.buildCentral(peerX);
        await h.port.connect(peerX);
        await h.flush();
        h.events.clear();

        central.notifications.addError(StateError('GATT stream error'));
        await h.flush();

        expect(errorLogs, isNotEmpty);
        expect(h.events.whereType<PortPeerDisconnected>(), isEmpty);

        // Data after the error still flows.
        central.notifications.add(Uint8List.fromList([1, 2]));
        await h.flush();
        expect(h.events.whereType<PortPeerData>(), hasLength(1));

        await h.dispose();
      },
    );
  });

  group('M21: double-connect to the same NodeId', () {
    test(
      'a second central connection for a live NodeId is dropped, keeping '
      'the established link',
      () async {
        final h = await _Harness.create();
        final first = h.buildCentral(peerX);
        await h.port.connect(peerX);
        await h.flush();
        expect(h.events.whereType<PortPeerConnected>(), hasLength(1));

        // iOS MAC rotation: a second candidate for the same peer.
        final second = h.buildCentral(peerX);
        await h.port.connect(peerX);
        await h.flush();

        expect(
          h.events.whereType<PortPeerConnected>(),
          hasLength(1),
          reason: 'no duplicate announcement for an already-live link',
        );
        verify(() => second.peerConn.disconnect()).called(1);
        verifyNever(() => first.peerConn.disconnect());
        expect(
          h.events.whereType<PortPeerDisconnected>(),
          isEmpty,
          reason: 'the surviving link must not be unregistered',
        );

        // Sends still go through the FIRST link's characteristic.
        await h.port.sendData(peerX, Uint8List.fromList([7]));
        verify(
          () => first.dataChar.write(
            any(),
            withResponse: any(named: 'withResponse'),
          ),
        ).called(1);

        await h.dispose();
      },
    );
  });

  group('WIRE4-9: a rejected peripheral link still carries outbound sends', () {
    test(
      'sendData after disconnectRole(peripheral) notifies on the '
      'still-alive link instead of throwing',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        when(
          () => h.server.notifyTo(any(), any(), data: any(named: 'data')),
        ).thenAnswer((_) async {});

        h.peerConnections.add(h.buildPeripheral(peerX, 'addr-x'));
        await h.flush();

        // What ConnectionManager does on a capacity rejection: the
        // peripheral role is torn down locally — but bluey has no
        // per-client disconnect, so the physical link stays up until the
        // central closes it. A rejection RE-send (the WIRE4-9 fix) must
        // be able to reach that still-connected central.
        await h.port.disconnectRole(peerX, ConnectionRole.peripheral);

        await h.port.sendData(peerX, Uint8List.fromList([9, 9]));

        verify(
          () => h.server.notifyTo(any(), any(), data: any(named: 'data')),
        ).called(1);
      },
    );
  });
}
