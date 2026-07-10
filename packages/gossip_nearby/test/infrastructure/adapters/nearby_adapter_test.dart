import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart' show LogLevel;
import 'package:gossip_nearby/src/domain/interfaces/nearby_port.dart';
import 'package:gossip_nearby/src/domain/value_objects/endpoint_id.dart';
import 'package:gossip_nearby/src/domain/value_objects/service_id.dart';
import 'package:gossip_nearby/src/infrastructure/adapters/nearby_adapter.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nearby_connections/nearby_connections.dart';

class MockNearby extends Mock implements Nearby {}

void main() {
  setUpAll(() {
    registerFallbackValue(Strategy.P2P_CLUSTER);
  });

  group('NearbyAdapter ALREADY_* recovery', () {
    late MockNearby nearby;
    late NearbyAdapter adapter;
    final serviceId = ServiceId('com.example.test');

    setUp(() {
      nearby = MockNearby();
      adapter = NearbyAdapter(nearby: nearby, strategy: Strategy.P2P_CLUSTER);
      // stopAllEndpoints is called whenever we adopt platform state, to
      // tear down orphaned platform connections. Stub it for every test
      // so adoption paths don't blow up on an unstubbed call.
      when(() => nearby.stopAllEndpoints()).thenAnswer((_) async {});
    });

    tearDown(() async {
      await adapter.dispose();
    });

    test(
      'startAdvertising adopts platform state when already advertising',
      () async {
        when(
          () => nearby.startAdvertising(
            any(),
            any(),
            onConnectionInitiated: any(named: 'onConnectionInitiated'),
            onConnectionResult: any(named: 'onConnectionResult'),
            onDisconnected: any(named: 'onDisconnected'),
            serviceId: any(named: 'serviceId'),
          ),
        ).thenThrow(
          PlatformException(
            code: 'Failure',
            message: '8001: STATUS_ALREADY_ADVERTISING',
          ),
        );
        when(() => nearby.stopAdvertising()).thenAnswer((_) async {});

        await expectLater(
          adapter.startAdvertising(serviceId, 'display'),
          completes,
        );

        // Adoption must drop orphaned platform connections so the higher
        // layers can re-handshake fresh.
        verify(() => nearby.stopAllEndpoints()).called(1);

        // Proves _isAdvertising was set to true: a subsequent stop must
        // actually call the platform (otherwise the early-return in
        // stopAdvertising would skip it).
        await adapter.stopAdvertising();
        verify(() => nearby.stopAdvertising()).called(1);
      },
    );

    test(
      'startDiscovery adopts platform state when already discovering',
      () async {
        when(
          () => nearby.startDiscovery(
            any(),
            any(),
            onEndpointFound: any(named: 'onEndpointFound'),
            onEndpointLost: any(named: 'onEndpointLost'),
            serviceId: any(named: 'serviceId'),
          ),
        ).thenThrow(
          PlatformException(
            code: 'Failure',
            message: '8002: STATUS_ALREADY_DISCOVERING',
          ),
        );
        when(() => nearby.stopDiscovery()).thenAnswer((_) async {});

        await expectLater(adapter.startDiscovery(serviceId), completes);

        verify(() => nearby.stopAllEndpoints()).called(1);

        await adapter.stopDiscovery();
        verify(() => nearby.stopDiscovery()).called(1);
      },
    );

    test('startAdvertising rethrows other PlatformExceptions', () async {
      when(
        () => nearby.startAdvertising(
          any(),
          any(),
          onConnectionInitiated: any(named: 'onConnectionInitiated'),
          onConnectionResult: any(named: 'onConnectionResult'),
          onDisconnected: any(named: 'onDisconnected'),
          serviceId: any(named: 'serviceId'),
        ),
      ).thenThrow(
        PlatformException(code: 'Failure', message: 'MISSING_PERMISSION'),
      );

      await expectLater(
        adapter.startAdvertising(serviceId, 'display'),
        throwsA(isA<PlatformException>()),
      );
    });

    test('startDiscovery rethrows other PlatformExceptions', () async {
      when(
        () => nearby.startDiscovery(
          any(),
          any(),
          onEndpointFound: any(named: 'onEndpointFound'),
          onEndpointLost: any(named: 'onEndpointLost'),
          serviceId: any(named: 'serviceId'),
        ),
      ).thenThrow(
        PlatformException(code: 'Failure', message: 'BLUETOOTH_DISABLED'),
      );

      await expectLater(
        adapter.startDiscovery(serviceId),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('NearbyAdapter connection acceptance', () {
    late MockNearby nearby;
    late NearbyAdapter adapter;
    final serviceId = ServiceId('com.example.test');

    setUp(() {
      nearby = MockNearby();
      adapter = NearbyAdapter(nearby: nearby, strategy: Strategy.P2P_CLUSTER);
      when(() => nearby.stopAllEndpoints()).thenAnswer((_) async {});
      when(() => nearby.stopAdvertising()).thenAnswer((_) async {});
      when(
        () => nearby.startAdvertising(
          any(),
          any(),
          onConnectionInitiated: any(named: 'onConnectionInitiated'),
          onConnectionResult: any(named: 'onConnectionResult'),
          onDisconnected: any(named: 'onDisconnected'),
          serviceId: any(named: 'serviceId'),
        ),
      ).thenAnswer((_) async => true);
    });

    tearDown(() async {
      await adapter.dispose();
    });

    /// Starts advertising and returns the captured onConnectionInitiated
    /// callback so tests can simulate an incoming connection.
    Future<OnConnectionInitiated> captureOnConnectionInitiated() async {
      await adapter.startAdvertising(serviceId, 'display');
      return verify(
            () => nearby.startAdvertising(
              any(),
              any(),
              onConnectionInitiated: captureAny(named: 'onConnectionInitiated'),
              onConnectionResult: any(named: 'onConnectionResult'),
              onDisconnected: any(named: 'onDisconnected'),
              serviceId: any(named: 'serviceId'),
            ),
          ).captured.single
          as OnConnectionInitiated;
    }

    test('emits ConnectionFailed without a type error when acceptConnection '
        'fails', () async {
      when(
        () => nearby.acceptConnection(
          any(),
          onPayLoadRecieved: any(named: 'onPayLoadRecieved'),
          onPayloadTransferUpdate: any(named: 'onPayloadTransferUpdate'),
        ),
      ).thenAnswer(
        (_) => Future<bool>.error(
          PlatformException(code: '8007', message: 'STATUS_BLUETOOTH_ERROR'),
        ),
      );

      final onConnectionInitiated = await captureOnConnectionInitiated();

      final events = <NearbyEvent>[];
      adapter.events.listen(events.add);

      onConnectionInitiated('ep1', ConnectionInfo('name', 'token', true));
      // The failed accept must resolve through catchError without an
      // unhandled TypeError reaching the zone.
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      final failed = events.first as ConnectionFailed;
      expect(failed.id, equals(EndpointId('ep1')));
      expect(failed.reason, contains('acceptConnection failed'));
    });
  });

  group('NearbyAdapter delivery observability', () {
    late MockNearby nearby;
    late NearbyAdapter adapter;
    late List<(LogLevel, String)> logs;
    final serviceId = ServiceId('com.example.test');

    setUp(() {
      nearby = MockNearby();
      logs = [];
      adapter = NearbyAdapter(
        nearby: nearby,
        strategy: Strategy.P2P_CLUSTER,
        onLog: (level, message, [error, stack]) => logs.add((level, message)),
      );
      when(() => nearby.stopAllEndpoints()).thenAnswer((_) async {});
      when(() => nearby.stopAdvertising()).thenAnswer((_) async {});
      when(
        () => nearby.startAdvertising(
          any(),
          any(),
          onConnectionInitiated: any(named: 'onConnectionInitiated'),
          onConnectionResult: any(named: 'onConnectionResult'),
          onDisconnected: any(named: 'onDisconnected'),
          serviceId: any(named: 'serviceId'),
        ),
      ).thenAnswer((_) async => true);
      when(
        () => nearby.acceptConnection(
          any(),
          onPayLoadRecieved: any(named: 'onPayLoadRecieved'),
          onPayloadTransferUpdate: any(named: 'onPayloadTransferUpdate'),
        ),
      ).thenAnswer((_) async => true);
    });

    tearDown(() async {
      await adapter.dispose();
    });

    /// Simulates an accepted incoming connection and returns the payload
    /// callbacks the adapter registered with the plugin.
    Future<(OnPayloadReceived, OnPayloadTransferUpdate)>
    acceptedConnectionCallbacks() async {
      await adapter.startAdvertising(serviceId, 'display');
      final onConnectionInitiated =
          verify(
                () => nearby.startAdvertising(
                  any(),
                  any(),
                  onConnectionInitiated: captureAny(
                    named: 'onConnectionInitiated',
                  ),
                  onConnectionResult: any(named: 'onConnectionResult'),
                  onDisconnected: any(named: 'onDisconnected'),
                  serviceId: any(named: 'serviceId'),
                ),
              ).captured.single
              as OnConnectionInitiated;

      onConnectionInitiated('ep1', ConnectionInfo('name', 'token', true));
      await Future<void>.delayed(Duration.zero);

      final captured = verify(
        () => nearby.acceptConnection(
          any(),
          onPayLoadRecieved: captureAny(named: 'onPayLoadRecieved'),
          onPayloadTransferUpdate: captureAny(named: 'onPayloadTransferUpdate'),
        ),
      ).captured;
      return (
        captured[0] as OnPayloadReceived,
        captured[1] as OnPayloadTransferUpdate,
      );
    }

    test('emits PayloadTransferFailed and logs at error level on transfer '
        'failure', () async {
      final (_, onTransferUpdate) = await acceptedConnectionCallbacks();

      final events = <NearbyEvent>[];
      adapter.events.listen(events.add);

      onTransferUpdate(
        'ep1',
        PayloadTransferUpdate(
          id: 7,
          bytesTransferred: 0,
          totalBytes: 100,
          status: PayloadStatus.FAILURE,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      final failed = events.first as PayloadTransferFailed;
      expect(failed.id, equals(EndpointId('ep1')));
      expect(failed.payloadId, equals(7));
      expect(logs.where((l) => l.$1 == LogLevel.error), isNotEmpty);
    });

    test('does not emit events for non-failure transfer updates', () async {
      final (_, onTransferUpdate) = await acceptedConnectionCallbacks();

      final events = <NearbyEvent>[];
      adapter.events.listen(events.add);

      for (final status in [PayloadStatus.SUCCESS, PayloadStatus.IN_PROGRESS]) {
        onTransferUpdate(
          'ep1',
          PayloadTransferUpdate(
            id: 7,
            bytesTransferred: 50,
            totalBytes: 100,
            status: status,
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
    });

    test('logs a warning when a non-bytes payload is dropped', () async {
      final (onPayloadReceived, _) = await acceptedConnectionCallbacks();

      final events = <NearbyEvent>[];
      adapter.events.listen(events.add);

      onPayloadReceived('ep1', Payload(id: 3, type: PayloadType.FILE));
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
      expect(
        logs.where((l) => l.$1 == LogLevel.warning && l.$2.contains('payload')),
        isNotEmpty,
      );
    });

    test('still forwards bytes payloads', () async {
      final (onPayloadReceived, _) = await acceptedConnectionCallbacks();

      final events = <NearbyEvent>[];
      adapter.events.listen(events.add);

      onPayloadReceived(
        'ep1',
        Payload(
          id: 3,
          type: PayloadType.BYTES,
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first, isA<PayloadReceived>());
    });

    test('logs a warning when requestConnection returns false', () async {
      when(
        () => nearby.requestConnection(
          any(),
          any(),
          onConnectionInitiated: any(named: 'onConnectionInitiated'),
          onConnectionResult: any(named: 'onConnectionResult'),
          onDisconnected: any(named: 'onDisconnected'),
        ),
      ).thenAnswer((_) async => false);

      await adapter.requestConnection(EndpointId('ep1'));

      expect(
        logs.where(
          (l) => l.$1 == LogLevel.warning && l.$2.contains('requestConnection'),
        ),
        isNotEmpty,
      );
    });
  });

  group('NearbyAdapter strategy plumbing', () {
    // Pin the contract that this commit establishes: the Strategy passed
    // to the constructor is the Strategy forwarded to the underlying
    // platform calls. Without this, a future regression that re-hardcodes
    // a value at the platform call would silently pass.
    late MockNearby nearby;
    final serviceId = ServiceId('com.example.test');

    setUp(() {
      nearby = MockNearby();
      when(() => nearby.stopAllEndpoints()).thenAnswer((_) async {});
    });

    test(
      'startAdvertising forwards the configured Strategy to the plugin',
      () async {
        final adapter = NearbyAdapter(
          nearby: nearby,
          strategy: Strategy.P2P_STAR,
        );
        addTearDown(adapter.dispose);
        when(
          () => nearby.startAdvertising(
            any(),
            any(),
            onConnectionInitiated: any(named: 'onConnectionInitiated'),
            onConnectionResult: any(named: 'onConnectionResult'),
            onDisconnected: any(named: 'onDisconnected'),
            serviceId: any(named: 'serviceId'),
          ),
        ).thenAnswer((_) async => true);

        await adapter.startAdvertising(serviceId, 'display');

        verify(
          () => nearby.startAdvertising(
            any(),
            Strategy.P2P_STAR,
            onConnectionInitiated: any(named: 'onConnectionInitiated'),
            onConnectionResult: any(named: 'onConnectionResult'),
            onDisconnected: any(named: 'onDisconnected'),
            serviceId: any(named: 'serviceId'),
          ),
        ).called(1);
      },
    );

    test(
      'startDiscovery forwards the configured Strategy to the plugin',
      () async {
        final adapter = NearbyAdapter(
          nearby: nearby,
          strategy: Strategy.P2P_STAR,
        );
        addTearDown(adapter.dispose);
        when(
          () => nearby.startDiscovery(
            any(),
            any(),
            onEndpointFound: any(named: 'onEndpointFound'),
            onEndpointLost: any(named: 'onEndpointLost'),
            serviceId: any(named: 'serviceId'),
          ),
        ).thenAnswer((_) async => true);

        await adapter.startDiscovery(serviceId);

        verify(
          () => nearby.startDiscovery(
            any(),
            Strategy.P2P_STAR,
            onEndpointFound: any(named: 'onEndpointFound'),
            onEndpointLost: any(named: 'onEndpointLost'),
            serviceId: any(named: 'serviceId'),
          ),
        ).called(1);
      },
    );
  });
}
