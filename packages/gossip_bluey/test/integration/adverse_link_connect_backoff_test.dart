import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../fakes/fake_bluey_port.dart';
import '_adverse_link_harness.dart';
import '_coordinator_helpers.dart';

/// Scenario: a peer's connect attempts fail N times before succeeding.
/// AutoConnectPolicy must respect exponential per-address backoff (no
/// hot loop hammering the peer on every 100ms scan re-advertisement),
/// eventually connect, and the coordinators must sync once the link is
/// finally up.
void main() {
  test('auto-connect backs off exponentially across connect failures and '
      'sync completes once connected', () async {
    final network = FakeBlueyNetwork();
    final idA = NodeId('11111111-1111-1111-1111-111111111111');
    final idB = NodeId('22222222-2222-2222-2222-222222222222');
    final serviceUuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');
    const initialBackoff = Duration(milliseconds: 250);

    // Directional star: A discovers and initiates; B only advertises,
    // so every connect attempt is A's and the attempt timeline below
    // is unambiguous.
    final a = await AdverseLinkNode.spawn(
      nodeId: idA,
      network: network,
      serviceUuid: serviceUuid,
      initialBackoff: initialBackoff,
      maxBackoff: const Duration(seconds: 2),
    );
    final b = await AdverseLinkNode.spawn(
      nodeId: idB,
      network: network,
      serviceUuid: serviceUuid,
    );

    // Fail the first 3 connect attempts to B, then let them succeed.
    var failuresLeft = 3;
    a.port.connectAndIdentifyFailureInjector = (address) {
      if (address.value != idB.value || failuresLeft == 0) return false;
      failuresLeft--;
      return true;
    };
    final attemptTimes = <DateTime>[];
    a.port.onConnectAndIdentify = (_) => attemptTimes.add(DateTime.now());

    await b.start(discover: false);
    await a.start(advertise: false);

    await waitFor(
      () async => a.isLinkedTo(idB) && b.isLinkedTo(idA),
      what: 'link up after backed-off retries',
      timeout: const Duration(seconds: 15),
    );

    // Exactly 3 failures + 1 success — the 100ms scan re-emissions in
    // between were absorbed by the backoff gate, not turned into a hot
    // loop of connect attempts.
    expect(a.port.connectAndIdentifyCallCount, equals(4));
    expect(failuresLeft, equals(0));

    // Each retry waited at least its (doubling) backoff window. The
    // policy computes nextAttempt from the failure instant, which is
    // never before the attempt's start time, so these bounds are exact.
    expect(attemptTimes, hasLength(4));
    Duration gap(int i) => attemptTimes[i + 1].difference(attemptTimes[i]);
    expect(gap(0), greaterThanOrEqualTo(initialBackoff));
    expect(gap(1), greaterThanOrEqualTo(initialBackoff * 2));
    expect(gap(2), greaterThanOrEqualTo(initialBackoff * 4));

    // With the link finally up, the full stack syncs.
    final channelId = ChannelId('demo');
    final streamId = StreamId('messages');
    final streamA = await a.joinChannel(
      channelId: channelId,
      streamId: streamId,
      peers: [idB],
    );
    await b.joinChannel(channelId: channelId, streamId: streamId, peers: [idA]);
    await a.coordinator.start();
    await b.coordinator.start();

    final payload = Uint8List.fromList([9, 8, 7]);
    await streamA.append(payload);
    await waitForEntryCount(b, channelId, streamId, 1);
    final entriesB = await b.entriesOf(channelId, streamId);
    expect(entriesB.single.payload, equals(payload));

    await a.dispose();
    await b.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
