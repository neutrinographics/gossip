import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/log_entry_id.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';

void main() {
  group('LogEntryId', () {
    test('two LogEntryIds with same author and sequence are equal', () {
      final author = NodeId('node-1');
      final id1 = LogEntryId(author, 5);
      final id2 = LogEntryId(author, 5);

      expect(id1, equals(id2));
    });

    test('LogEntryIds with different authors are not equal', () {
      final id1 = LogEntryId(NodeId('node-1'), 5);
      final id2 = LogEntryId(NodeId('node-2'), 5);

      expect(id1, isNot(equals(id2)));
    });

    test('LogEntryIds with different sequences are not equal', () {
      final author = NodeId('node-1');
      final id1 = LogEntryId(author, 5);
      final id2 = LogEntryId(author, 6);

      expect(id1, isNot(equals(id2)));
    });

    test('hashCode is consistent with equality', () {
      final author1 = NodeId('node-1');
      final author2 = NodeId('node-2');
      final id1 = LogEntryId(author1, 5);
      final id2 = LogEntryId(author1, 5);
      final id3 = LogEntryId(author2, 5);

      expect(id1.hashCode, equals(id2.hashCode));
      expect(id1.hashCode, isNot(equals(id3.hashCode)));
    });

    test('toString returns readable representation', () {
      final id = LogEntryId(NodeId('node-1'), 42);

      expect(id.toString(), equals('LogEntryId(node-1:42)'));
    });

    group('invariant validation', () {
      test('constructor throws ArgumentError when sequence is zero', () {
        expect(
          () => LogEntryId(NodeId('node-1'), 0),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('constructor throws ArgumentError when sequence is negative', () {
        expect(
          () => LogEntryId(NodeId('node-1'), -1),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('constructor accepts sequence of 1', () {
        final id = LogEntryId(NodeId('node-1'), 1);
        expect(id.sequence, equals(1));
      });

      test('constructor accepts large positive sequence', () {
        final id = LogEntryId(NodeId('node-1'), 999999);
        expect(id.sequence, equals(999999));
      });
    });
  });
}
