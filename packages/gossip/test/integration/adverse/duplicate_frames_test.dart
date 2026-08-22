import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/protocol/messages/delta_request.dart';
import 'package:gossip/src/protocol/messages/delta_response.dart';
import 'package:gossip/src/protocol/messages/digest_request.dart';
import 'package:gossip/src/protocol/messages/digest_response.dart';
import 'package:gossip/src/protocol/protocol_codec.dart';

import '../../support/test_network.dart';

/// Duplicate delivery: the transport hands the receiver identical bytes
/// twice for digest, delta-request, and delta-response frames.
///
/// The protocol must treat redelivery as a no-op:
/// - no entry is applied twice (counts and payloads stay exact),
/// - no spurious errors reach the application via `Coordinator.errors`,
/// - convergence happens within the same round budget as a clean network.
void main() {
  group('Duplicate Frames', () {
    late TestNetwork network;
    late List<SyncError> surfacedErrors;
    late List<StreamSubscription<SyncError>> errorSubscriptions;
    final channelId = ChannelId('duplicate-frames-channel');
    final streamId = StreamId('data');
    final codec = ProtocolCodec();

    setUp(() async {
      network = await TestNetwork.create(['node1', 'node2']);
      await network.connect('node1', 'node2');
      await network.setupChannel(channelId, streamId);

      // Collect every error either node surfaces to the application, so
      // tests can assert duplicated frames never produce spurious errors.
      // Note: coordinators are NOT started here — tests that need the
      // anti-entropy pull path seed writes before calling startAll().
      surfacedErrors = [];
      errorSubscriptions = [
        for (final node in network.nodes)
          node.coordinator.errors.listen(surfacedErrors.add),
      ];
    });

    tearDown(() async {
      for (final subscription in errorSubscriptions) {
        await subscription.cancel();
      }
      await network.dispose();
    });

    /// Duplicates every frame in both directions and returns a live set of
    /// the protocol message types crossing the wire, so tests can prove the
    /// duplicated traffic actually contained the frame kinds under test.
    ///
    /// Implementation: an identity corruption transform is used as a tap.
    /// The bus evaluates corruption BEFORE duplication, so the tap observes
    /// each unique frame exactly once and the identical bytes are then
    /// delivered twice. The duplication count is far larger than any test's
    /// traffic, so every frame in the test is duplicated.
    Set<Type> duplicateAllFramesAndTapTypes() {
      final seenTypes = <Type>{};
      Uint8List tap(Uint8List bytes) {
        seenTypes.add(codec.decode(bytes).runtimeType);
        return bytes;
      }

      for (final (from, to) in [('node1', 'node2'), ('node2', 'node1')]) {
        network.corruptLink(from, to, tap);
        network.duplicateNext(from, to, count: 1000);
      }
      return seenTypes;
    }

    /// Returns the sorted first payload byte of every entry a node holds,
    /// making double-applied entries visible as repeated values.
    Future<List<int>> payloadMarkers(String nodeName) async {
      final entries = await network[nodeName].entries(channelId, streamId);
      return entries.map((e) => e.payload[0]).toList()..sort();
    }

    test(
      'duplicated digest and delta frames apply each entry exactly once',
      () async {
        final seenTypes = duplicateAllFramesAndTapTypes();

        // Seed divergent histories BEFORE starting, so convergence must go
        // through the full anti-entropy exchange in both directions:
        // DigestRequest → DigestResponse → DeltaRequest → DeltaResponse.
        await network['node1'].write(channelId, streamId, [1]);
        await network['node1'].write(channelId, streamId, [2]);
        await network['node1'].write(channelId, streamId, [3]);
        await network['node2'].write(channelId, streamId, [4]);
        await network['node2'].write(channelId, streamId, [5]);

        await network.startAll();
        await network.runRounds(10);

        // Prove the duplicated traffic contained every frame kind under
        // test — each of these crossed the wire and was delivered twice.
        expect(
          seenTypes,
          containsAll([
            DigestRequest,
            DigestResponse,
            DeltaRequest,
            DeltaResponse,
          ]),
          reason:
              'the duplicated window must cover all sync frame kinds; '
              'saw only: $seenTypes',
        );

        // Redelivered frames must not double-apply: exact counts and each
        // payload present exactly once on both nodes.
        expect(await network.hasConverged(channelId, streamId), isTrue);
        expect(await payloadMarkers('node1'), equals([1, 2, 3, 4, 5]));
        expect(await payloadMarkers('node2'), equals([1, 2, 3, 4, 5]));

        expect(
          surfacedErrors,
          isEmpty,
          reason:
              'duplicate delivery must not surface errors to the app; '
              'got: $surfacedErrors',
        );
      },
    );

    test(
      'duplicated frames in steady state add no entries and no errors',
      () async {
        // Converge on a clean network first.
        await network['node1'].write(channelId, streamId, [1]);
        await network.startAll();
        await network.runRounds(5);
        expect(await network.hasConverged(channelId, streamId), isTrue);

        // With no new writes, gossip rounds are pure digest exchanges.
        // Duplicating them must be a complete no-op.
        final seenTypes = duplicateAllFramesAndTapTypes();
        await network.runRounds(10);

        expect(
          seenTypes,
          containsAll([DigestRequest, DigestResponse]),
          reason:
              'steady-state rounds must have exchanged digests; '
              'saw only: $seenTypes',
        );
        expect(await payloadMarkers('node1'), equals([1]));
        expect(await payloadMarkers('node2'), equals([1]));
        expect(
          surfacedErrors,
          isEmpty,
          reason:
              'duplicated steady-state digests must not surface errors; '
              'got: $surfacedErrors',
        );
      },
    );

    test('convergence is unaffected across repeated sync cycles under '
        'constant duplication', () async {
      // Duplication stays on for the whole test. Writes after start also
      // exercise the reactive-push path (a DeltaResponse sent without a
      // preceding DeltaRequest), delivered twice like everything else.
      final seenTypes = duplicateAllFramesAndTapTypes();
      await network.startAll();

      // Alternate authors across cycles; each cycle must converge within
      // the same round budget as a clean network (5 rounds, matching the
      // basic sync tests).
      final expectedMarkers = <int>[];
      for (var cycle = 1; cycle <= 3; cycle++) {
        final author = cycle.isOdd ? 'node1' : 'node2';
        await network[author].write(channelId, streamId, [cycle]);
        expectedMarkers.add(cycle);

        await network.runRounds(5);

        expect(
          await network.hasConverged(channelId, streamId),
          isTrue,
          reason: 'cycle $cycle failed to converge under duplication',
        );
        expect(await payloadMarkers('node1'), equals(expectedMarkers));
        expect(await payloadMarkers('node2'), equals(expectedMarkers));
      }

      expect(
        seenTypes,
        contains(DeltaResponse),
        reason:
            'post-start writes must have pushed entries as DeltaResponse '
            'frames; saw only: $seenTypes',
      );
      expect(
        surfacedErrors,
        isEmpty,
        reason:
            'duplicate delivery must not surface errors to the app; '
            'got: $surfacedErrors',
      );
    });
  });
}
