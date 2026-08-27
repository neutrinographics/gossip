import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/sync/application/materialization/fold_cursor.dart';

void main() {
  group('FoldCursor construction invariant', () {
    test('legacy cursor (both author and sequence null) constructs fine', () {
      final cursor = FoldCursor(Hlc(1, 0));

      expect(cursor.author, isNull);
      expect(cursor.sequence, isNull);
    });

    test('full cursor (both author and sequence provided) constructs fine', () {
      final cursor = FoldCursor(Hlc(1, 0), author: NodeId('a'), sequence: 3);

      expect(cursor.author, equals(NodeId('a')));
      expect(cursor.sequence, equals(3));
    });

    test('author without sequence throws in checked mode', () {
      expect(
        () => FoldCursor(Hlc(1, 0), author: NodeId('a')),
        throwsA(isA<AssertionError>()),
      );
    });

    test('sequence without author throws in checked mode', () {
      expect(
        () => FoldCursor(Hlc(1, 0), sequence: 3),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
