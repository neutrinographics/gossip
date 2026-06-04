// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'package:bluey/bluey.dart' as bluey;
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/gossip_bluey.dart';
import 'package:gossip_chat/presentation/controllers/chat_controller.dart';

ConnectionStatus _compute({
  BluetoothAdapterState bluetooth = BluetoothAdapterState.on,
  bluey.AdvertisingState adv = bluey.AdvertisingState.idle,
  bluey.ScanState scan = bluey.ScanState.stopped,
  int peers = 0,
}) =>
    computeConnectionStatus(
      bluetoothState: bluetooth,
      advertisingState: adv,
      scanState: scan,
      connectedPeerCount: peers,
    );

void main() {
  group('computeConnectionStatus precedence', () {
    test('bluetoothOff has highest precedence (overrides connected, peers)',
        () {
      expect(
        _compute(
          bluetooth: BluetoothAdapterState.off,
          adv: bluey.AdvertisingState.advertising,
          scan: bluey.ScanState.scanning,
          peers: 3,
        ),
        ConnectionStatus.bluetoothOff,
      );
    });

    test('invalidated wins over connected and meshActive', () {
      expect(
        _compute(
          adv: bluey.AdvertisingState.invalidated,
          scan: bluey.ScanState.scanning,
          peers: 5,
        ),
        ConnectionStatus.invalidated,
      );
      expect(
        _compute(
          adv: bluey.AdvertisingState.advertising,
          scan: bluey.ScanState.invalidated,
          peers: 5,
        ),
        ConnectionStatus.invalidated,
      );
    });

    test('connected when peers > 0 (and not invalidated)', () {
      expect(
        _compute(
          adv: bluey.AdvertisingState.advertising,
          scan: bluey.ScanState.scanning,
          peers: 1,
        ),
        ConnectionStatus.connected,
      );
    });

    test('meshActive when both adv + scan active and no peers', () {
      expect(
        _compute(
          adv: bluey.AdvertisingState.advertising,
          scan: bluey.ScanState.scanning,
        ),
        ConnectionStatus.meshActive,
      );
    });

    test('advertising transients map correctly', () {
      expect(_compute(adv: bluey.AdvertisingState.starting),
          ConnectionStatus.advertisingStarting);
      expect(_compute(adv: bluey.AdvertisingState.advertising),
          ConnectionStatus.advertising);
      expect(_compute(adv: bluey.AdvertisingState.stopping),
          ConnectionStatus.advertisingStopping);
    });

    test('discovery transients map correctly', () {
      expect(_compute(scan: bluey.ScanState.starting),
          ConnectionStatus.discoveryStarting);
      expect(_compute(scan: bluey.ScanState.scanning),
          ConnectionStatus.discovering);
      expect(_compute(scan: bluey.ScanState.stopping),
          ConnectionStatus.discoveryStopping);
    });

    test('disconnected when adv idle and scan stopped', () {
      expect(_compute(), ConnectionStatus.disconnected);
    });

    test('advertising takes precedence over scan in mixed transient combos',
        () {
      // Both adv and scan in transient states — adv wins per the
      // documented precedence (adv transients listed before scan).
      expect(
        _compute(
          adv: bluey.AdvertisingState.starting,
          scan: bluey.ScanState.starting,
        ),
        ConnectionStatus.advertisingStarting,
      );
    });

    test('non-on bluetooth states all map to bluetoothOff', () {
      for (final state in [
        BluetoothAdapterState.off,
        BluetoothAdapterState.unauthorized,
        BluetoothAdapterState.unsupported,
        BluetoothAdapterState.unknown,
      ]) {
        expect(_compute(bluetooth: state), ConnectionStatus.bluetoothOff);
      }
    });
  });
}
