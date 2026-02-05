import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart' as gossip;
import 'package:gossip_chat/presentation/managers/signal_strength_manager.dart';

void main() {
  group('SignalStrengthManager', () {
    late SignalStrengthManager manager;

    setUp(() {
      manager = SignalStrengthManager();
    });

    tearDown(() {
      manager.dispose();
    });

    group('getSmoothedFailedProbeCount', () {
      test('returns 0 for unknown peer', () {
        final peerId = gossip.NodeId('unknown-peer');

        expect(manager.getSmoothedFailedProbeCount(peerId), equals(0));
      });

      test('returns 0 when penalty is below low threshold', () {
        final peerId = gossip.NodeId('peer-1');

        // Penalty starts at 0, should return 0
        expect(manager.getSmoothedFailedProbeCount(peerId), equals(0));
      });
    });

    group('updatePenalty', () {
      test('increases penalty when failedProbeCount increases', () {
        final peerId = gossip.NodeId('peer-1');

        // First update with 0 failures
        manager.updatePenalty(peerId, 0);
        expect(manager.getSmoothedFailedProbeCount(peerId), equals(0));

        // Failure count increases to 1 - penalty should increase by 0.4
        manager.updatePenalty(peerId, 1);
        // 0.4 is above 0.3 threshold, so should return 1
        expect(manager.getSmoothedFailedProbeCount(peerId), equals(1));
      });

      test('does not increase penalty when failedProbeCount stays same', () {
        final peerId = gossip.NodeId('peer-1');

        manager.updatePenalty(peerId, 1);
        final countAfterFirst = manager.getSmoothedFailedProbeCount(peerId);

        // Same failure count - penalty should not increase
        manager.updatePenalty(peerId, 1);
        expect(
          manager.getSmoothedFailedProbeCount(peerId),
          equals(countAfterFirst),
        );
      });

      test('caps penalty at 1.0 (returns 2 for probe count)', () {
        final peerId = gossip.NodeId('peer-1');

        // Multiple failures to exceed 1.0 cap
        manager.updatePenalty(peerId, 0);
        manager.updatePenalty(peerId, 1); // +0.4 = 0.4
        manager.updatePenalty(peerId, 2); // +0.4 = 0.8
        manager.updatePenalty(peerId, 3); // +0.4 = 1.0 (capped)

        // Penalty >= 0.6 should return 2
        expect(manager.getSmoothedFailedProbeCount(peerId), equals(2));
      });

      test('returns 1 when penalty is in medium range', () {
        final peerId = gossip.NodeId('peer-1');

        // Single failure = 0.4 penalty (in 0.3-0.6 range)
        manager.updatePenalty(peerId, 0);
        manager.updatePenalty(peerId, 1);

        expect(manager.getSmoothedFailedProbeCount(peerId), equals(1));
      });
    });

    group('decayPenalties', () {
      test('decays penalty by decay rate', () {
        final peerId = gossip.NodeId('peer-1');

        // Set up penalty
        manager.updatePenalty(peerId, 0);
        manager.updatePenalty(peerId, 1); // penalty = 0.4

        // Decay once (0.4 - 0.1 = 0.3)
        final changed = manager.decayPenalties();
        expect(changed, isTrue);

        // 0.3 is at the threshold boundary, should still return 1
        expect(manager.getSmoothedFailedProbeCount(peerId), equals(1));
      });

      test('removes penalty when decayed to zero', () {
        final peerId = gossip.NodeId('peer-1');

        // Set up small penalty
        manager.updatePenalty(peerId, 0);
        manager.updatePenalty(peerId, 1); // penalty = 0.4

        // Decay multiple times to reach 0
        manager.decayPenalties(); // 0.3
        manager.decayPenalties(); // 0.2
        manager.decayPenalties(); // 0.1
        manager.decayPenalties(); // 0 (removed)

        expect(manager.getSmoothedFailedProbeCount(peerId), equals(0));
      });

      test('returns false when no penalties to decay', () {
        final changed = manager.decayPenalties();
        expect(changed, isFalse);
      });
    });

    group('clearPeer', () {
      test('removes all tracking for a peer', () {
        final peerId = gossip.NodeId('peer-1');

        manager.updatePenalty(peerId, 0);
        manager.updatePenalty(peerId, 1);
        expect(manager.getSmoothedFailedProbeCount(peerId), equals(1));

        manager.clearPeer(peerId);

        expect(manager.getSmoothedFailedProbeCount(peerId), equals(0));
      });
    });

    group('clearAll', () {
      test('removes all tracking for all peers', () {
        final peer1 = gossip.NodeId('peer-1');
        final peer2 = gossip.NodeId('peer-2');

        manager.updatePenalty(peer1, 0);
        manager.updatePenalty(peer1, 1);
        manager.updatePenalty(peer2, 0);
        manager.updatePenalty(peer2, 1);

        manager.clearAll();

        expect(manager.getSmoothedFailedProbeCount(peer1), equals(0));
        expect(manager.getSmoothedFailedProbeCount(peer2), equals(0));
      });
    });

    group('constants', () {
      test('penalty increment is 0.4', () {
        expect(SignalStrengthManager.penaltyIncrement, equals(0.4));
      });

      test('decay rate is 0.1', () {
        expect(SignalStrengthManager.decayRate, equals(0.1));
      });

      test('low threshold is 0.3', () {
        expect(SignalStrengthManager.lowThreshold, equals(0.3));
      });

      test('medium threshold is 0.6', () {
        expect(SignalStrengthManager.mediumThreshold, equals(0.6));
      });
    });
  });
}
