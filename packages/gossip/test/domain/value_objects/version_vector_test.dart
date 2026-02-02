import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/version_vector.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';

void main() {
  group('VersionVector', () {
    final node1 = NodeId('node-1');
    final node2 = NodeId('node-2');
    final node3 = NodeId('node-3');

    test('empty version vector returns 0 for any node', () {
      const vector = VersionVector.empty;

      expect(vector[node1], equals(0));
      expect(vector[node2], equals(0));
    });

    test('indexing returns stored value for known node', () {
      final vector = VersionVector({node1: 5, node2: 10});

      expect(vector[node1], equals(5));
      expect(vector[node2], equals(10));
    });

    test('increment creates new vector with node incremented by 1', () {
      final vector = VersionVector({node1: 5});
      final result = vector.increment(node1);

      expect(result[node1], equals(6));
      expect(vector[node1], equals(5)); // Original unchanged
    });

    test('increment on unknown node sets it to 1', () {
      const vector = VersionVector.empty;
      final result = vector.increment(node1);

      expect(result[node1], equals(1));
    });

    test('set creates new vector with node at specified value', () {
      final vector = VersionVector({node1: 5});
      final result = vector.set(node1, 10);

      expect(result[node1], equals(10));
      expect(vector[node1], equals(5)); // Original unchanged
    });

    test('merge takes max of each node\'s value', () {
      final vector1 = VersionVector({node1: 5, node2: 3});
      final vector2 = VersionVector({node1: 2, node2: 8});
      final result = vector1.merge(vector2);

      expect(result[node1], equals(5));
      expect(result[node2], equals(8));
    });

    test('merge includes nodes from both vectors', () {
      final vector1 = VersionVector({node1: 5});
      final vector2 = VersionVector({node2: 8});
      final result = vector1.merge(vector2);

      expect(result[node1], equals(5));
      expect(result[node2], equals(8));
    });

    test('diff returns nodes where other has higher values', () {
      final vector1 = VersionVector({node1: 5, node2: 3});
      final vector2 = VersionVector({node1: 8, node2: 2, node3: 5});
      final missing = vector1.diff(vector2);

      expect(missing[node1], equals(5)); // We have 5, they have 8
      expect(missing.containsKey(node2), isFalse); // We have 3, they have 2
      expect(missing[node3], equals(0)); // We have 0, they have 5
    });

    test('diff returns our value (not other\'s) for missing entries', () {
      final vector1 = VersionVector({node1: 5});
      final vector2 = VersionVector({node1: 10, node2: 3});
      final missing = vector1.diff(vector2);

      expect(missing[node1], equals(5)); // Our value
      expect(missing[node2], equals(0)); // Our value (we have 0)
    });

    test('dominates returns true when all our values >= other\'s', () {
      final vector1 = VersionVector({node1: 5, node2: 8});
      final vector2 = VersionVector({node1: 3, node2: 8});

      expect(vector1.dominates(vector2), isTrue);
    });

    test('dominates returns false when any value < other\'s', () {
      final vector1 = VersionVector({node1: 5, node2: 3});
      final vector2 = VersionVector({node1: 3, node2: 8});

      expect(vector1.dominates(vector2), isFalse);
    });

    test('entries returns unmodifiable map', () {
      final vector = VersionVector({node1: 5});
      final entries = vector.entries;

      expect(entries[node1], equals(5));
      expect(() => entries[node2] = 10, throwsUnsupportedError);
    });

    test('isEmpty returns true for empty vector', () {
      const vector = VersionVector.empty;

      expect(vector.isEmpty, isTrue);
    });

    test('isEmpty returns false for non-empty vector', () {
      final vector = VersionVector({node1: 5});

      expect(vector.isEmpty, isFalse);
    });

    test('two vectors with same entries are equal (order-independent)', () {
      final vector1 = VersionVector({node1: 5, node2: 8});
      final vector2 = VersionVector({node2: 8, node1: 5});

      expect(vector1, equals(vector2));
    });

    test('hashCode is order-independent', () {
      final vector1 = VersionVector({node1: 5, node2: 8});
      final vector2 = VersionVector({node2: 8, node1: 5});

      expect(vector1.hashCode, equals(vector2.hashCode));
    });

    group('invariant validation', () {
      test('constructor throws ArgumentError when sequence is negative', () {
        expect(() => VersionVector({node1: -1}), throwsA(isA<ArgumentError>()));
      });

      test(
        'constructor throws ArgumentError for multiple negative sequences',
        () {
          expect(
            () => VersionVector({node1: 5, node2: -1}),
            throwsA(isA<ArgumentError>()),
          );
        },
      );

      test('constructor accepts sequence of 0', () {
        final vector = VersionVector({node1: 0});
        expect(vector[node1], equals(0));
      });

      test('constructor accepts positive sequences', () {
        final vector = VersionVector({node1: 5, node2: 100});
        expect(vector[node1], equals(5));
        expect(vector[node2], equals(100));
      });
    });
  });
}
