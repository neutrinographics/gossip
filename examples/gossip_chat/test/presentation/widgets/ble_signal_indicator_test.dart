import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_chat/presentation/view_models/ble_health.dart';
import 'package:gossip_chat/presentation/widgets/ble_signal_indicator.dart';

void main() {
  Future<void> pump(
    WidgetTester t,
    BleHealth health, {
    bool scanning = true,
  }) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BleSignalIndicator(health: health, scanningActive: scanning),
        ),
      ),
    );
  }

  group('BleSignalIndicator', () {
    testWidgets('renders without throwing for every BleHealth value',
        (t) async {
      for (final h in BleHealth.values) {
        await pump(t, h);
        expect(find.byType(BleSignalIndicator), findsOneWidget);
      }
    });

    testWidgets('renders without throwing when scanning is false', (t) async {
      await pump(t, BleHealth.excellent, scanning: false);
      expect(find.byType(BleSignalIndicator), findsOneWidget);
    });

    testWidgets('respects custom size', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BleSignalIndicator(
              health: BleHealth.good,
              size: 32,
            ),
          ),
        ),
      );
      final size = t.getSize(find.byType(BleSignalIndicator));
      expect(size.width, 32);
      expect(size.height, 32);
    });
  });
}
