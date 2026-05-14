import 'dart:async';
import 'dart:typed_data';

import 'package:bluey/bluey.dart' as bluey;
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/src/domain/errors/bluetooth_unavailable_exception.dart';
import 'package:gossip_bluey/src/domain/value_objects/bluetooth_adapter_state.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';
import 'package:gossip_bluey/src/infrastructure/adapters/bluey_port_impl.dart';
import 'package:mocktail/mocktail.dart';

class _MockBluey extends Mock implements bluey.Bluey {}

class _MockServer extends Mock implements bluey.Server {}

void main() {
  setUpAll(() {
    registerFallbackValue(
      bluey.HostedService(
        uuid: bluey.UUID('00000000-0000-0000-0000-000000000000'),
        characteristics: const [],
      ),
    );
    registerFallbackValue(const <bluey.UUID>[]);
  });

  final localId = NodeId('11111111-1111-1111-1111-111111111111');

  // Helper: build a BlueyPortImpl with a mock that publishes the given
  // initial state and exposes a controllable stateStream.
  ({BlueyPortImpl port, StreamController<bluey.BluetoothState> stateCtrl})
  buildPort({bluey.BluetoothState initialState = bluey.BluetoothState.on}) {
    final mock = _MockBluey();
    // Test helper: lifecycle managed by individual tests via stateCtrl.close
    // or implicitly by test teardown — no explicit close needed here.
    // ignore: close_sinks
    final stateCtrl = StreamController<bluey.BluetoothState>.broadcast();
    when(() => mock.currentState).thenReturn(initialState);
    when(() => mock.stateStream).thenAnswer((_) => stateCtrl.stream);
    final port = BlueyPortImpl(localNodeId: localId, blueyInstance: mock);
    return (port: port, stateCtrl: stateCtrl);
  }

  group('BlueyPortImpl adapter-state observation', () {
    test('initial bluetoothAdapterState reflects bluey.currentState', () {
      final fixture = buildPort(initialState: bluey.BluetoothState.off);
      expect(
        fixture.port.bluetoothAdapterState,
        equals(BluetoothAdapterState.off),
      );
    });

    test('bluetoothStateStream emits current value on subscription', () async {
      final fixture = buildPort(initialState: bluey.BluetoothState.on);
      final received = <BluetoothAdapterState>[];
      final sub = fixture.port.bluetoothStateStream.listen(received.add);
      await Future<void>.delayed(Duration.zero);
      expect(received, equals([BluetoothAdapterState.on]));
      await sub.cancel();
    });

    test(
      'pushing a state transition updates getter and emits on stream',
      () async {
        final fixture = buildPort(initialState: bluey.BluetoothState.on);
        final received = <BluetoothAdapterState>[];
        final sub = fixture.port.bluetoothStateStream.listen(received.add);
        await Future<void>.delayed(Duration.zero);
        received.clear(); // discard initial replay

        fixture.stateCtrl.add(bluey.BluetoothState.off);
        await Future<void>.delayed(Duration.zero);

        expect(
          fixture.port.bluetoothAdapterState,
          equals(BluetoothAdapterState.off),
        );
        expect(received, equals([BluetoothAdapterState.off]));
        await sub.cancel();
      },
    );

    test('maps each bluey state to the corresponding domain enum', () {
      final cases = <bluey.BluetoothState, BluetoothAdapterState>{
        bluey.BluetoothState.on: BluetoothAdapterState.on,
        bluey.BluetoothState.off: BluetoothAdapterState.off,
        bluey.BluetoothState.unauthorized: BluetoothAdapterState.unauthorized,
        bluey.BluetoothState.unsupported: BluetoothAdapterState.unsupported,
        bluey.BluetoothState.unknown: BluetoothAdapterState.unknown,
      };
      for (final entry in cases.entries) {
        final fixture = buildPort(initialState: entry.key);
        expect(
          fixture.port.bluetoothAdapterState,
          equals(entry.value),
          reason: 'bluey ${entry.key} should map to ${entry.value}',
        );
      }
    });

    test('transition to non-on updates state and fires no errors', () async {
      final fixture = buildPort(initialState: bluey.BluetoothState.on);

      // The fuller behaviour — clearing internal maps and firing
      // PortPeerDisconnected per peer — requires a full server.peerConnections
      // setup that mocktail-mocking bluey.Bluey doesn't readily provide.
      // We assert the observable surface: the state transition itself lands.
      // Per-peer cleanup is exercised by hardware testing and the
      // _invalidateLiveState method is unit-callable for future tests.
      fixture.stateCtrl.add(bluey.BluetoothState.off);
      await Future<void>.delayed(Duration.zero);

      expect(
        fixture.port.bluetoothAdapterState,
        equals(BluetoothAdapterState.off),
      );
    });

    test('transition back to on does not auto-reinit; consumer must call '
        'startAdvertising explicitly', () async {
      final fixture = buildPort(initialState: bluey.BluetoothState.on);
      fixture.stateCtrl.add(bluey.BluetoothState.off);
      await Future<void>.delayed(Duration.zero);
      fixture.stateCtrl.add(bluey.BluetoothState.on);
      await Future<void>.delayed(Duration.zero);

      expect(
        fixture.port.bluetoothAdapterState,
        equals(BluetoothAdapterState.on),
      );
      // No assertion on side-effects: we explicitly do NOT auto-reinit.
      // The port is back in the enabled state and ready for the consumer
      // to call startAdvertising again. The gate test in Task 7 verifies
      // operations succeed post-on.
    });

    test('startAdvertising throws BluetoothUnavailableException after adapter '
        'goes off', () async {
      final fixture = buildPort(initialState: bluey.BluetoothState.on);
      fixture.stateCtrl.add(bluey.BluetoothState.off);
      await Future<void>.delayed(Duration.zero);

      expect(
        () => fixture.port.startAdvertising(
          serviceUuid: ServiceUuid('f0000000-0000-0000-0000-000000000000'),
          displayName: 'Local',
          localNodeId: localId,
        ),
        throwsA(isA<BluetoothUnavailableException>()),
      );
    });

    test('sendData throws BluetoothUnavailableException with nodeId context '
        'after adapter goes off', () async {
      final fixture = buildPort(initialState: bluey.BluetoothState.on);
      fixture.stateCtrl.add(bluey.BluetoothState.off);
      await Future<void>.delayed(Duration.zero);

      final peer = NodeId('22222222-2222-2222-2222-222222222222');
      await expectLater(
        () => fixture.port.sendData(peer, Uint8List.fromList([1, 2, 3])),
        throwsA(
          isA<BluetoothUnavailableException>().having(
            (e) => e.nodeId,
            'nodeId',
            equals(peer),
          ),
        ),
      );
    });

    test(
      'after returning to on, operations no longer throw the disabled gate',
      () async {
        final fixture = buildPort(initialState: bluey.BluetoothState.on);
        fixture.stateCtrl.add(bluey.BluetoothState.off);
        await Future<void>.delayed(Duration.zero);

        // Phase 1: confirm the gate is actually closed while off. Without
        // this precondition, a silent success in phase 2 would make the
        // negative assertion pass vacuously.
        await expectLater(
          () => fixture.port.startAdvertising(
            serviceUuid: ServiceUuid('f0000000-0000-0000-0000-000000000000'),
            displayName: 'Local',
            localNodeId: localId,
          ),
          throwsA(isA<BluetoothUnavailableException>()),
        );

        // Phase 2: transition back to on; the gate should now be open.
        fixture.stateCtrl.add(bluey.BluetoothState.on);
        await Future<void>.delayed(Duration.zero);

        // Operation may still fail (the underlying server is null after
        // invalidation), but it will fail with the regular StateError —
        // not BluetoothUnavailableException. The point is the gate is open.
        //
        // We cannot use `isNot(throwsA(...))` directly because the matcher
        // pipeline doesn't compose negation with async throws — it reports
        // both a synchronous "Closure didn't throw" failure and the later
        // async error. Catch manually and assert on the type.
        Object? thrown;
        try {
          await fixture.port.startAdvertising(
            serviceUuid: ServiceUuid('f0000000-0000-0000-0000-000000000000'),
            displayName: 'Local',
            localNodeId: localId,
          );
        } catch (e) {
          thrown = e;
        }
        // Either it succeeded (against the mock) or threw something
        // OTHER than BluetoothUnavailableException — both are acceptable
        // "gate is open" signals.
        expect(thrown, isNot(isA<BluetoothUnavailableException>()));
      },
    );

    test('startAdvertising translates a thrown bluey error into '
        'BluetoothUnavailableException with cause', () async {
      final mock = _MockBluey();
      // Test helper: lifecycle managed implicitly via test teardown.
      // ignore: close_sinks
      final stateCtrl = StreamController<bluey.BluetoothState>.broadcast();
      when(() => mock.currentState).thenReturn(bluey.BluetoothState.on);
      when(() => mock.stateStream).thenAnswer((_) => stateCtrl.stream);

      // Stub server() to return a server whose addService throws.
      final mockServer = _MockServer();
      when(() => mock.server()).thenReturn(mockServer);
      when(
        () => mockServer.addService(any()),
      ).thenThrow(Exception('synthetic-platform-failure'));

      final port = BlueyPortImpl(localNodeId: localId, blueyInstance: mock);

      await expectLater(
        () => port.startAdvertising(
          serviceUuid: ServiceUuid('f0000000-0000-0000-0000-000000000000'),
          displayName: 'Local',
          localNodeId: localId,
        ),
        throwsA(
          isA<BluetoothUnavailableException>().having(
            (e) => e.cause.toString(),
            'cause',
            contains('synthetic-platform-failure'),
          ),
        ),
      );
    });

    test(
      'startAdvertising resets internal state after a thrown bluey error',
      () async {
        final mock = _MockBluey();
        // Test helper: lifecycle managed implicitly via test teardown.
        // ignore: close_sinks
        final stateCtrl = StreamController<bluey.BluetoothState>.broadcast();
        when(() => mock.currentState).thenReturn(bluey.BluetoothState.on);
        when(() => mock.stateStream).thenAnswer((_) => stateCtrl.stream);
        final mockServer = _MockServer();
        when(() => mock.server()).thenReturn(mockServer);
        // First call throws; second call succeeds.
        var addServiceCalls = 0;
        when(() => mockServer.addService(any())).thenAnswer((_) async {
          addServiceCalls++;
          if (addServiceCalls == 1) {
            throw Exception('first-call-fails');
          }
        });
        // For the success path we also need peerConnections, disconnections,
        // writeRequests streams + startAdvertising itself to be stubbable.
        when(
          () => mockServer.peerConnections,
        ).thenAnswer((_) => const Stream.empty());
        when(
          () => mockServer.disconnections,
        ).thenAnswer((_) => const Stream.empty());
        when(
          () => mockServer.writeRequests,
        ).thenAnswer((_) => const Stream.empty());
        when(
          () => mockServer.startAdvertising(
            name: any(named: 'name'),
            services: any(named: 'services'),
            peerDiscoverable: any(named: 'peerDiscoverable'),
          ),
        ).thenAnswer((_) async {});

        final port = BlueyPortImpl(localNodeId: localId, blueyInstance: mock);
        final svcUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');

        // First attempt fails.
        await expectLater(
          () => port.startAdvertising(
            serviceUuid: svcUuid,
            displayName: 'Local',
            localNodeId: localId,
          ),
          throwsA(isA<BluetoothUnavailableException>()),
        );

        // Second attempt succeeds — state was reset.
        await expectLater(
          port.startAdvertising(
            serviceUuid: svcUuid,
            displayName: 'Local',
            localNodeId: localId,
          ),
          completes,
        );
      },
    );
  });
}
