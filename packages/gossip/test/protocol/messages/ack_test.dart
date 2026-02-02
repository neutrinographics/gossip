import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/protocol/messages/ack.dart';

void main() {
  group('Ack', () {
    test('creates ack message with sender and sequence', () {
      final sender = NodeId('sender-1');
      final sequence = 42;

      final ack = Ack(sender: sender, sequence: sequence);

      expect(ack.sender, equals(sender));
      expect(ack.sequence, equals(sequence));
    });
  });
}
