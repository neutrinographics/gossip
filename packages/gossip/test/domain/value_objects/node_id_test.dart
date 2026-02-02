import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';

void main() {
  group('NodeId', () {
    test('two NodeIds with same value are equal', () {
      final id1 = NodeId('test-id-123');
      final id2 = NodeId('test-id-123');

      expect(id1, equals(id2));
    });

    test('two NodeIds with different values are not equal', () {
      final id1 = NodeId('test-id-123');
      final id2 = NodeId('test-id-456');

      expect(id1, isNot(equals(id2)));
    });

    test('hashCode is consistent with equality', () {
      final id1 = NodeId('test-id-123');
      final id2 = NodeId('test-id-123');
      final id3 = NodeId('test-id-456');

      expect(id1.hashCode, equals(id2.hashCode));
      expect(id1.hashCode, isNot(equals(id3.hashCode)));
    });

    test('toString returns readable representation', () {
      final id = NodeId('test-id-123');

      expect(id.toString(), equals('NodeId(test-id-123)'));
    });

    test('identical values produce equal NodeIds', () {
      final id1 = NodeId('test-id-123');
      final id2 = NodeId('test-id-123');

      expect(id1, equals(id2));
      expect(id1.hashCode, equals(id2.hashCode));
    });

    test('constructor throws ArgumentError when value is empty', () {
      expect(() => NodeId(''), throwsA(isA<ArgumentError>()));
    });

    test('constructor throws ArgumentError when value is only whitespace', () {
      expect(() => NodeId('   '), throwsA(isA<ArgumentError>()));
    });
  });
}
