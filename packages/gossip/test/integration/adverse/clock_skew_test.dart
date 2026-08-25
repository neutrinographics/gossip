import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/coordinator/coordinator_config.dart';

import '../../support/test_network.dart';

/// Advances each node's virtual clock by its own per-round step, [rounds]
/// times.
///
/// Unlike [TestNetwork.runRounds], which ticks every node uniformly, this
/// simulates clock-RATE skew: a node given a smaller step has a slower wall
/// clock AND schedules its own gossip/probe rounds less often, because both
/// HLC physical time and round scheduling are driven by the same virtual
/// clock — just like a device with a slow oscillator.
Future<void> runSkewedRounds(
  TestNetwork network,
  int rounds,
  Map<String, Duration> stepPerRound,
) async {
  for (var i = 0; i < rounds; i++) {
    for (final entry in stepPerRound.entries) {
      await network[entry.key].timePort.advance(entry.value);
    }
  }
}

/// Clock-skew scenarios: nodes whose virtual clocks start far apart and/or
/// advance at different rates.
///
/// Three regimes are covered:
/// 1. Large initial OFFSET within the HLC drift bound — receive() adopts the
///    remote physical time, so causal (write-after-receive) ordering holds
///    even when the writer's wall clock is far behind.
/// 2. Divergent clock RATES — the slow node gossips less often and its wall
///    clock falls ever further behind, but convergence and a globally
///    consistent HLC order are unaffected.
/// 3. Skew BEYOND `CoordinatorConfig.hlcMaxDrift` — entries still sync (the
///    bound never rejects entries), but the receiver's clock is clamped to
///    `local now + hlcMaxDrift` instead of adopting the insane timestamp, so
///    one broken clock cannot poison the mesh. The designed trade-off is
///    that causality is NOT preserved across an out-of-bound clock.
void main() {
  group('Clock Skew', () {
    group('Initial offset within the drift bound', () {
      // 30 minutes is severe for phone clocks but comfortably inside the
      // default hlcMaxDrift of 1 hour, so normal HLC adoption applies.
      const offset = Duration(minutes: 30);

      test('concurrent writes converge despite a 30-minute offset', () async {
        final network = await TestNetwork.create(['ahead', 'behind']);
        addTearDown(network.dispose);
        await network.connect('ahead', 'behind');

        final channelId = ChannelId('offset-converge-channel');
        final streamId = StreamId('events');
        await network.setupChannel(channelId, streamId);

        // 'ahead' boots with its clock 30 minutes in the future.
        await network['ahead'].timePort.advance(offset);

        // Both write before any sync — concurrent entries from clocks that
        // disagree by 30 minutes.
        await network['ahead'].write(channelId, streamId, [0xA1]);
        await network['behind'].write(channelId, streamId, [0xB1]);

        await network.startAll();
        await network.runRounds(10);

        expect(
          await network.hasConverged(channelId, streamId),
          isTrue,
          reason: 'a constant clock offset must not block convergence',
        );
        expect(
          await network['behind'].entryCount(channelId, streamId),
          equals(2),
        );

        // Entry timestamps are author-generated and travel unmodified, so
        // the offset is visible in the synced entries.
        final entries = await network['behind'].entries(channelId, streamId);
        final aheadEntry = entries.firstWhere((e) => e.payload[0] == 0xA1);
        final behindEntry = entries.firstWhere((e) => e.payload[0] == 0xB1);
        expect(
          aheadEntry.timestamp.physicalMs - behindEntry.timestamp.physicalMs,
          greaterThanOrEqualTo(offset.inMilliseconds),
          reason: 'synced entries carry their original skewed timestamps',
        );
      });

      test(
        'write-after-receive on the behind node stays causally ordered',
        () async {
          final network = await TestNetwork.create(['ahead', 'behind']);
          addTearDown(network.dispose);
          await network.connect('ahead', 'behind');

          final channelId = ChannelId('offset-causal-channel');
          final streamId = StreamId('events');
          await network.setupChannel(channelId, streamId);

          await network['ahead'].timePort.advance(offset);
          await network.startAll();

          // ahead writes with a future-dated HLC.
          await network['ahead'].write(channelId, streamId, [1]);
          await network.runRounds(5);
          expect(
            await network['behind'].entryCount(channelId, streamId),
            equals(1),
          );

          // behind's wall clock is still ~30 minutes in the past, but its
          // HLC adopted ahead's physical time on receive (skew < maxDrift).
          final behindWallMs = network['behind'].timePort.nowMs;
          expect(
            behindWallMs,
            lessThan(offset.inMilliseconds),
            reason: 'precondition: behind wall clock has not caught up',
          );

          await network['behind'].write(channelId, streamId, [2]);
          await network.runRounds(5);

          final entries = await network['ahead'].entries(channelId, streamId);
          expect(entries.length, equals(2));
          final first = entries.firstWhere((e) => e.payload[0] == 1);
          final second = entries.firstWhere((e) => e.payload[0] == 2);

          expect(
            second.timestamp.compareTo(first.timestamp),
            greaterThan(0),
            reason:
                'an entry written after receiving must order after the '
                'received entry, regardless of the writer\'s wall clock',
          );
          expect(
            second.timestamp.physicalMs,
            greaterThanOrEqualTo(offset.inMilliseconds),
            reason:
                'behind\'s HLC must have adopted the ahead physical time '
                '(skew is within hlcMaxDrift), not used its own wall clock',
          );
        },
      );
    });

    group('Divergent clock rates', () {
      // fast ticks 1000ms per round, slow only 250ms: a 4x rate skew that
      // widens the wall-clock gap every round. The slow node also runs its
      // gossip loop less often (its 1s conservative interval takes ~4 rounds
      // of virtual time to elapse), so phases get generous round budgets.
      const steps = {
        'fast': Duration(milliseconds: 1000),
        'slow': Duration(milliseconds: 250),
      };

      test('nodes ticking at different rates converge and agree on '
          'HLC order', () async {
        final network = await TestNetwork.create(['fast', 'slow']);
        addTearDown(network.dispose);
        await network.connect('fast', 'slow');

        final channelId = ChannelId('rate-skew-channel');
        final streamId = StreamId('events');
        await network.setupChannel(channelId, streamId);

        // Concurrent writes at t=0 on both clocks.
        await network['fast'].write(channelId, streamId, [0xF1]);
        await network['slow'].write(channelId, streamId, [0xB1]);

        await network.startAll();
        await runSkewedRounds(network, 20, steps);

        // Mid-run writes: the wall-clock gap is now 15 seconds and growing.
        await network['fast'].write(channelId, streamId, [0xF2]);
        await network['slow'].write(channelId, streamId, [0xB2]);
        await runSkewedRounds(network, 20, steps);

        expect(
          await network.hasConverged(channelId, streamId),
          isTrue,
          reason: 'a 4x clock-rate skew must not block convergence',
        );
        expect(
          await network['slow'].entryCount(channelId, streamId),
          equals(4),
        );

        // Both nodes must agree on the total order (LogEntry.compareTo:
        // HLC with author tiebreak) — HLCs synced from a skewed clock sort
        // identically everywhere.
        final fastEntries = await network['fast'].entries(channelId, streamId);
        final slowEntries = await network['slow'].entries(channelId, streamId);
        fastEntries.sort();
        slowEntries.sort();
        expect(
          fastEntries.map((e) => e.id).toList(),
          equals(slowEntries.map((e) => e.id).toList()),
          reason: 'all nodes must agree on the HLC sort order',
        );
      });

      test('causal chain across skewed rates preserves HLC order', () async {
        final network = await TestNetwork.create(['fast', 'slow']);
        addTearDown(network.dispose);
        await network.connect('fast', 'slow');

        final channelId = ChannelId('rate-causal-channel');
        final streamId = StreamId('events');
        await network.setupChannel(channelId, streamId);
        await network.startAll();

        // Causal chain alternating between the fast and slow clock:
        // slow writes [1] → fast sees it, writes [2] → slow sees [2] with a
        // wall clock far behind [2]'s physical time, writes [3].
        await network['slow'].write(channelId, streamId, [1]);
        await runSkewedRounds(network, 15, steps);

        await network['fast'].write(channelId, streamId, [2]);
        await runSkewedRounds(network, 15, steps);

        // The slow node's wall clock (7.5s) is far behind the fast node's
        // (30s), so only HLC adoption on receive can order [3] after [2].
        expect(
          network['slow'].timePort.nowMs,
          lessThan(network['fast'].timePort.nowMs),
          reason: 'precondition: the rate skew has separated the clocks',
        );
        await network['slow'].write(channelId, streamId, [3]);
        await runSkewedRounds(network, 15, steps);

        expect(await network.hasConverged(channelId, streamId), isTrue);

        for (final name in ['fast', 'slow']) {
          final entries = await network[name].entries(channelId, streamId);
          expect(entries.length, equals(3));
          entries.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          expect(
            entries.map((e) => e.payload[0]).toList(),
            equals([1, 2, 3]),
            reason:
                'HLC order on $name must match the causal write order '
                'despite the 4x clock-rate skew',
          );
        }
      });
    });

    group('HLC drift bound (hlcMaxDrift)', () {
      test('entries authored beyond the drift bound still sync', () async {
        // A tiny 5-second bound with a one-hour skew: the insane clock is
        // far beyond anything the bound tolerates.
        final network = await TestNetwork.create([
          'sane',
          'insane',
        ], config: const CoordinatorConfig(hlcMaxDrift: Duration(seconds: 5)));
        addTearDown(network.dispose);
        await network.connect('sane', 'insane');

        final channelId = ChannelId('drift-sync-channel');
        final streamId = StreamId('events');
        await network.setupChannel(channelId, streamId);

        await network['insane'].timePort.advance(const Duration(hours: 1));
        await network['insane'].write(channelId, streamId, [0xEE]);

        await network.startAll();
        await network.runRounds(10);

        // The drift bound protects the receiver's CLOCK; it never rejects
        // entries. The insane entry syncs with its original timestamp.
        expect(
          await network.hasConverged(channelId, streamId),
          isTrue,
          reason: 'out-of-bound timestamps must not block sync',
        );
        final entries = await network['sane'].entries(channelId, streamId);
        expect(entries.length, equals(1));
        expect(
          entries.single.timestamp.physicalMs,
          greaterThanOrEqualTo(const Duration(hours: 1).inMilliseconds),
          reason: 'the entry keeps its author-generated future timestamp',
        );
      });

      test('out-of-bound remote clock is clamped, not adopted', () async {
        const maxDrift = Duration(seconds: 5);
        final network = await TestNetwork.create([
          'sane',
          'insane',
        ], config: const CoordinatorConfig(hlcMaxDrift: maxDrift));
        addTearDown(network.dispose);
        await network.connect('sane', 'insane');

        final channelId = ChannelId('drift-clamp-channel');
        final streamId = StreamId('events');
        await network.setupChannel(channelId, streamId);

        await network['insane'].timePort.advance(const Duration(hours: 1));
        await network['insane'].write(channelId, streamId, [0xEE]);

        await network.startAll();
        await network.runRounds(10);
        expect(
          await network['sane'].entryCount(channelId, streamId),
          equals(1),
        );

        // sane writes after receiving the hour-ahead entry. Its clock was
        // clamped to `local now + hlcMaxDrift` on receive, so the new entry
        // must stay near sane's wall clock instead of jumping an hour ahead.
        await network['sane'].write(channelId, streamId, [0x01]);
        await network.runRounds(10);

        expect(await network.hasConverged(channelId, streamId), isTrue);
        final entries = await network['insane'].entries(channelId, streamId);
        final insaneEntry = entries.firstWhere((e) => e.payload[0] == 0xEE);
        final saneEntry = entries.firstWhere((e) => e.payload[0] == 0x01);

        expect(
          saneEntry.timestamp.physicalMs,
          lessThanOrEqualTo(
            network['sane'].timePort.nowMs + maxDrift.inMilliseconds,
          ),
          reason:
              'the drift bound caps how far a broken remote clock can drag '
              'the local HLC ahead of the local wall clock',
        );

        // DESIGNED trade-off, not a bug: beyond hlcMaxDrift the remote clock
        // is treated as broken, so the write-after-receive orders BEFORE the
        // insane entry. Causality is deliberately sacrificed to stop a
        // broken clock from poisoning every peer (see HlcClock.maxDrift).
        expect(
          saneEntry.timestamp.compareTo(insaneEntry.timestamp),
          lessThan(0),
          reason:
              'beyond the bound the insane timestamp is clamped rather than '
              'adopted, so causal ordering across it is intentionally lost',
        );
      });

      test('skew within the drift bound keeps causal adoption', () async {
        // Contrast case: a 20-second skew under a 30-second bound merges
        // with normal HLC causality semantics.
        const skew = Duration(seconds: 20);
        final network = await TestNetwork.create([
          'sane',
          'skewed',
        ], config: const CoordinatorConfig(hlcMaxDrift: Duration(seconds: 30)));
        addTearDown(network.dispose);
        await network.connect('sane', 'skewed');

        final channelId = ChannelId('drift-within-channel');
        final streamId = StreamId('events');
        await network.setupChannel(channelId, streamId);

        await network['skewed'].timePort.advance(skew);
        await network['skewed'].write(channelId, streamId, [0xAA]);

        await network.startAll();
        await network.runRounds(5);
        expect(
          await network['sane'].entryCount(channelId, streamId),
          equals(1),
        );

        // sane's wall clock (5s) is still behind the skewed timestamp (20s),
        // so ordering after it requires the receive-time adoption.
        expect(
          network['sane'].timePort.nowMs,
          lessThan(skew.inMilliseconds),
          reason: 'precondition: sane wall clock is behind the skewed entry',
        );
        await network['sane'].write(channelId, streamId, [0xBB]);
        await network.runRounds(5);

        final entries = await network['skewed'].entries(channelId, streamId);
        expect(entries.length, equals(2));
        final skewedEntry = entries.firstWhere((e) => e.payload[0] == 0xAA);
        final saneEntry = entries.firstWhere((e) => e.payload[0] == 0xBB);

        expect(
          saneEntry.timestamp.compareTo(skewedEntry.timestamp),
          greaterThan(0),
          reason:
              'within hlcMaxDrift the remote time is adopted, preserving '
              'write-after-receive causality',
        );
        expect(
          saneEntry.timestamp.physicalMs,
          greaterThanOrEqualTo(skew.inMilliseconds),
          reason: 'the adopted physical time, not the wall clock, was used',
        );
      });
    });
  });
}
