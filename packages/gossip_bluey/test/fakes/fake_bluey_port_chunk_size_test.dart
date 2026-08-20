import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart' show NodeId;

import 'fake_bluey_port.dart';

void main() {
  test('the fake defaults to the un-negotiated BLE write payload (20 bytes) '
      'so tests run at real chunking pressure', () {
    final network = FakeBlueyNetwork();
    final port = FakeBlueyPort(localNodeId: NodeId('a'), network: network);

    // WIRE4-8: an Android link on which nobody negotiated MTU carries 20
    // bytes per write. A fake defaulting to 200 understates chunking 10x
    // and hides frame-reassembly pressure from every test.
    expect(port.chunkSizeFor(NodeId('b')), 20);
  });
}
