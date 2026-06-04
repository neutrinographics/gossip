import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_chat/application/services/gossip_config_service.dart';
import 'package:gossip_chat/presentation/screens/settings_sheet.dart';

void main() {
  group('SettingsSheet', () {
    testWidgets('renders both sliders with "Adaptive" labels by default',
        (t) async {
      final cfg = GossipConfigService();
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SettingsSheet(config: cfg)),
      ));
      expect(find.text('Gossip round interval'), findsOneWidget);
      expect(find.text('SWIM probe interval'), findsOneWidget);
      expect(find.text('Adaptive'), findsWidgets);
    });

    testWidgets('shows restart hint when networkingActive is true',
        (t) async {
      final cfg = GossipConfigService();
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsSheet(config: cfg, networkingActive: true),
        ),
      ));
      expect(find.text('Restart networking to apply.'), findsOneWidget);
    });

    testWidgets('omits restart hint when networkingActive is false',
        (t) async {
      final cfg = GossipConfigService();
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SettingsSheet(config: cfg)),
      ));
      expect(find.text('Restart networking to apply.'), findsNothing);
    });

    testWidgets('"Adaptive" button resets value to null', (t) async {
      final cfg = GossipConfigService();
      cfg.setGossipInterval(const Duration(milliseconds: 250));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: SettingsSheet(config: cfg)),
      ));
      // Tap the FIRST "Adaptive" TextButton (the one tied to the gossip slider).
      await t.tap(find.widgetWithText(TextButton, 'Adaptive').first);
      await t.pump();
      expect(cfg.gossipInterval, isNull);
    });
  });
}
