import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/protocol/messages/ping.dart';

void main() {
  group('Ping', () {
    test('creates ping message with sender and sequence', () {
      final sender = NodeId('sender-1');
      final sequence = 42;

      final ping = Ping(sender: sender, sequence: sequence);

      expect(ping.sender, equals(sender));
      expect(ping.sequence, equals(sequence));
    });
  });
}
