import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_chat/presentation/view_models/discovered_peer.dart';
import 'package:gossip_chat/presentation/widgets/peer_status_pill.dart';

void main() {
  Future<void> pumpPill(
    WidgetTester tester,
    DiscoveredPeerStatus status,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PeerStatusPill(status: status))),
    );
  }

  group('PeerStatusPill', () {
    testWidgets('discovered renders "Nearby"', (t) async {
      await pumpPill(t, DiscoveredPeerStatus.discovered);
      expect(find.text('Nearby'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('connecting renders label + spinner', (t) async {
      await pumpPill(t, DiscoveredPeerStatus.connecting);
      expect(find.text('Connecting…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('connected renders "Connected" no spinner', (t) async {
      await pumpPill(t, DiscoveredPeerStatus.connected);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('suspected renders "Unstable"', (t) async {
      await pumpPill(t, DiscoveredPeerStatus.suspected);
      expect(find.text('Unstable'), findsOneWidget);
    });

    testWidgets('unreachable renders "Disconnected"', (t) async {
      await pumpPill(t, DiscoveredPeerStatus.unreachable);
      expect(find.text('Disconnected'), findsOneWidget);
    });

    testWidgets('disconnecting renders label + spinner', (t) async {
      await pumpPill(t, DiscoveredPeerStatus.disconnecting);
      expect(find.text('Disconnecting…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('failed renders "Failed"', (t) async {
      await pumpPill(t, DiscoveredPeerStatus.failed);
      expect(find.text('Failed'), findsOneWidget);
    });
  });
}
