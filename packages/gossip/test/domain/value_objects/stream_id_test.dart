import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';

void main() {
  group('StreamId', () {
    test('two StreamIds with same value are equal', () {
      final id1 = StreamId('stream-123');
      final id2 = StreamId('stream-123');

      expect(id1, equals(id2));
    });

    test('two StreamIds with different values are not equal', () {
      final id1 = StreamId('stream-123');
      final id2 = StreamId('stream-456');

      expect(id1, isNot(equals(id2)));
    });

    test('hashCode is consistent with equality', () {
      final id1 = StreamId('stream-123');
      final id2 = StreamId('stream-123');
      final id3 = StreamId('stream-456');

      expect(id1.hashCode, equals(id2.hashCode));
      expect(id1.hashCode, isNot(equals(id3.hashCode)));
    });

    test('toString returns readable representation', () {
      final id = StreamId('stream-123');

      expect(id.toString(), equals('StreamId(stream-123)'));
    });

    test('constructor throws ArgumentError when value is empty', () {
      expect(() => StreamId(''), throwsA(isA<ArgumentError>()));
    });

    test('constructor throws ArgumentError when value is only whitespace', () {
      expect(() => StreamId('   '), throwsA(isA<ArgumentError>()));
    });
  });
}
