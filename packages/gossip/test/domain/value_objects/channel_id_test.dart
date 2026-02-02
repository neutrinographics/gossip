import 'package:test/test.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';

void main() {
  group('ChannelId', () {
    test('two ChannelIds with same value are equal', () {
      final id1 = ChannelId('channel-123');
      final id2 = ChannelId('channel-123');

      expect(id1, equals(id2));
    });

    test('two ChannelIds with different values are not equal', () {
      final id1 = ChannelId('channel-123');
      final id2 = ChannelId('channel-456');

      expect(id1, isNot(equals(id2)));
    });

    test('hashCode is consistent with equality', () {
      final id1 = ChannelId('channel-123');
      final id2 = ChannelId('channel-123');
      final id3 = ChannelId('channel-456');

      expect(id1.hashCode, equals(id2.hashCode));
      expect(id1.hashCode, isNot(equals(id3.hashCode)));
    });

    test('toString returns readable representation', () {
      final id = ChannelId('channel-123');

      expect(id.toString(), equals('ChannelId(channel-123)'));
    });

    test('constructor throws ArgumentError when value is empty', () {
      expect(() => ChannelId(''), throwsA(isA<ArgumentError>()));
    });

    test('constructor throws ArgumentError when value is only whitespace', () {
      expect(() => ChannelId('   '), throwsA(isA<ArgumentError>()));
    });
  });
}
