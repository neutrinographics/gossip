import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
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
      adapter = NearbyAdapter(nearby: nearby);
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
}
