import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/gossip_bluey.dart';
import 'package:gossip_chat/presentation/widgets/topology_controls.dart';

void main() {
  Future<void> pump(
    WidgetTester t, {
    AdvertisingState adv = AdvertisingState.idle,
    ScanState scan = ScanState.stopped,
    ConnectionMode mode = ConnectionMode.manual,
    VoidCallback? onToggleAdvertise,
    VoidCallback? onToggleDiscover,
    ValueChanged<ConnectionMode>? onModeChanged,
  }) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopologyControls(
            advertisingState: adv,
            scanState: scan,
            mode: mode,
            onToggleAdvertise: onToggleAdvertise ?? () {},
            onToggleDiscover: onToggleDiscover ?? () {},
            onModeChanged: onModeChanged ?? (_) {},
          ),
        ),
      ),
    );
  }

  group('TopologyControls', () {
    testWidgets('renders for every AdvertisingState value', (t) async {
      for (final s in AdvertisingState.values) {
        await pump(t, adv: s);
        expect(find.byType(TopologyControls), findsOneWidget);
      }
    });

    testWidgets('renders for every ScanState value', (t) async {
      for (final s in ScanState.values) {
        await pump(t, scan: s);
        expect(find.byType(TopologyControls), findsOneWidget);
      }
    });

    testWidgets('advertising state shows "Advertising"', (t) async {
      await pump(t, adv: AdvertisingState.advertising);
      expect(find.text('Advertising'), findsOneWidget);
    });

    testWidgets('starting shows transient spinner + "Starting…"', (t) async {
      await pump(t, adv: AdvertisingState.starting);
      expect(find.text('Starting…'), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
    });

    testWidgets('invalidated shows "Reset" label', (t) async {
      await pump(t, adv: AdvertisingState.invalidated);
      expect(find.text('Reset advertise'), findsOneWidget);
    });

    testWidgets('tapping advertise chip fires onToggleAdvertise', (t) async {
      var taps = 0;
      await pump(
        t,
        adv: AdvertisingState.idle,
        onToggleAdvertise: () => taps++,
      );
      await t.tap(find.text('Advertise'));
      await t.pump();
      expect(taps, 1);
    });

    testWidgets('tapping discover chip fires onToggleDiscover', (t) async {
      var taps = 0;
      await pump(
        t,
        scan: ScanState.stopped,
        onToggleDiscover: () => taps++,
      );
      await t.tap(find.text('Discover'));
      await t.pump();
      expect(taps, 1);
    });

    testWidgets('advertise chip is disabled while starting', (t) async {
      var taps = 0;
      await pump(
        t,
        adv: AdvertisingState.starting,
        onToggleAdvertise: () => taps++,
      );
      // Find the InkWell wrapping "Starting…" and verify onTap is null.
      final inkWells = t.widgetList<InkWell>(find.byType(InkWell)).toList();
      // (One InkWell per chip; both share the same widget type, so we
      // assert at least one has onTap == null. A more targeted finder
      // by descendant text is possible if needed.)
      expect(inkWells.any((w) => w.onTap == null), isTrue);
      // Sanity: tapping doesn't increment.
      await t.tap(find.text('Starting…').first);
      await t.pump();
      expect(taps, 0);
    });

    testWidgets('mode segmented control fires onModeChanged', (t) async {
      ConnectionMode? received;
      await pump(
        t,
        mode: ConnectionMode.manual,
        onModeChanged: (m) => received = m,
      );
      // Tap the "Mesh" segment.
      await t.tap(find.text('Mesh'));
      await t.pump();
      expect(received, ConnectionMode.auto);
    });

    testWidgets('renders for all four ConnectionMode/state combos', (t) async {
      // Sanity: a few representative combos.
      await pump(
        t,
        mode: ConnectionMode.auto,
        adv: AdvertisingState.advertising,
        scan: ScanState.scanning,
      );
      expect(find.byType(TopologyControls), findsOneWidget);
      await pump(
        t,
        mode: ConnectionMode.manual,
        adv: AdvertisingState.advertising,
        scan: ScanState.stopped,
      );
      expect(find.byType(TopologyControls), findsOneWidget);
    });
  });
}
