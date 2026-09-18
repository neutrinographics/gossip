import 'package:test/test.dart';
import 'package:gossip/src/coordinator/coordinator_config.dart';
import 'package:gossip/src/membership/domain/messages/ack.dart';
import 'package:gossip/src/membership/domain/messages/ping_req.dart';
import 'package:gossip/src/membership/infrastructure/membership_message_codec.dart';
import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/interfaces/message_port.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_version.dart';

import '../support/test_network.dart';

/// The receive-only contract the mixed fleet relies on: a relay request
/// from a peer on an older build is decoded by the real coordinator and
/// codec, and produces no frame back and no error.
void main() {
  test('an inbound relay request is decoded and ignored end to end', () async {
    // Periodic loops parked far past the test horizon so the only traffic
    // after settling is what the relay request itself would cause.
    final network = await TestNetwork.create(
      ['nodeA', 'requester', 'target'],
      config: const CoordinatorConfig(
        gossipInterval: Duration(hours: 1),
        probeInterval: Duration(hours: 1),
      ),
    );
    addTearDown(network.dispose);
    await network.connectAll();
    await network.startAll();
    // Let the connect-time bootstrap probes and their Acks settle.
    await network.runRounds(3, advanceMs: 2000);

    final nodeA = network['nodeA'];
    final requester = network['requester'];
    final target = network['target'];

    final errors = <SyncError>[];
    final errorSub = nodeA.coordinator.errors.listen(errors.add);
    addTearDown(errorSub.cancel);
    final toRequester = <IncomingMessage>[];
    final requesterSub = requester.messagePort.incoming.listen(toRequester.add);
    addTearDown(requesterSub.cancel);
    final toTarget = <IncomingMessage>[];
    final targetSub = target.messagePort.incoming.listen(toTarget.add);
    addTearDown(targetSub.cancel);

    final codec = MembershipMessageCodec(wireVersion: WireVersion.v1);
    await requester.messagePort.send(
      nodeA.id,
      codec.encode(
        PingReq(sender: requester.id, sequence: 7, target: target.id),
      ),
    );
    await network.runRounds(3, advanceMs: 2000);

    final forwardedAcks = toRequester
        .map((m) => codec.decode(m.bytes))
        .whereType<Ack>()
        .where((ack) => ack.sequence == 7);
    expect(forwardedAcks, isEmpty, reason: 'no Ack is forwarded back');
    expect(
      toTarget.where((m) => m.sender == nodeA.id),
      isEmpty,
      reason: 'no probe is relayed to the target',
    );
    expect(errors, isEmpty);
  });
}
