import 'package:test/test.dart';
import 'package:gossip/src/domain/entities/stream_config.dart';

void main() {
  group('StreamConfig', () {
    test('default constructor has expected defaults', () {
      final config = StreamConfig();

      expect(config.maxBufferSizePerAuthor, equals(1000));
      expect(config.maxTotalBufferEntries, equals(10000));
    });

    test('can set custom values', () {
      final config = StreamConfig(
        maxBufferSizePerAuthor: 500,
        maxTotalBufferEntries: 5000,
      );

      expect(config.maxBufferSizePerAuthor, equals(500));
      expect(config.maxTotalBufferEntries, equals(5000));
    });

    test('defaults constant is available', () {
      expect(StreamConfig.defaults.maxBufferSizePerAuthor, equals(1000));
      expect(StreamConfig.defaults.maxTotalBufferEntries, equals(10000));
    });

    test('equality compares all fields', () {
      final config1 = StreamConfig(
        maxBufferSizePerAuthor: 500,
        maxTotalBufferEntries: 5000,
      );

      final config2 = StreamConfig(
        maxBufferSizePerAuthor: 500,
        maxTotalBufferEntries: 5000,
      );

      final config3 = StreamConfig(
        maxBufferSizePerAuthor: 600, // Different
        maxTotalBufferEntries: 5000,
      );

      expect(config1, equals(config2));
      expect(config1, isNot(equals(config3)));
    });

    test('hashCode is consistent', () {
      final config1 = StreamConfig(
        maxBufferSizePerAuthor: 500,
        maxTotalBufferEntries: 5000,
      );

      final config2 = StreamConfig(
        maxBufferSizePerAuthor: 500,
        maxTotalBufferEntries: 5000,
      );

      expect(config1.hashCode, equals(config2.hashCode));
    });
  });
}
