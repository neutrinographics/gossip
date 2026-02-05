import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_chat/domain/entities/channel_metadata.dart';
import 'package:gossip_chat/infrastructure/codecs/channel_metadata_codec.dart';

void main() {
  group('ChannelMetadataCodec', () {
    late ChannelMetadataCodec codec;

    setUp(() {
      codec = const ChannelMetadataCodec();
    });

    group('encode/decode roundtrip', () {
      test('should encode and decode channel metadata successfully', () {
        // Arrange
        final metadata = ChannelMetadata(
          name: 'General',
          createdAt: DateTime(2024, 1, 15, 10, 30, 0),
        );

        // Act
        final encoded = codec.encode(metadata);
        final decoded = codec.decode(encoded);

        // Assert
        expect(decoded, isNotNull);
        expect(decoded!.name, metadata.name);
        expect(decoded.createdAt, metadata.createdAt);
      });

      test('should handle empty channel name', () {
        // Arrange
        final metadata = ChannelMetadata(
          name: '',
          createdAt: DateTime(2024, 1, 15, 11, 0, 0),
        );

        // Act
        final encoded = codec.encode(metadata);
        final decoded = codec.decode(encoded);

        // Assert
        expect(decoded, isNotNull);
        expect(decoded!.name, '');
      });

      test('should handle special characters in channel name', () {
        // Arrange
        final metadata = ChannelMetadata(
          name: 'Channel 你好 🎉 #test',
          createdAt: DateTime(2024, 1, 15, 12, 0, 0),
        );

        // Act
        final encoded = codec.encode(metadata);
        final decoded = codec.decode(encoded);

        // Assert
        expect(decoded, isNotNull);
        expect(decoded!.name, metadata.name);
      });

      test('should handle long channel names', () {
        // Arrange
        final longName = 'Channel ${'A' * 500}';
        final metadata = ChannelMetadata(
          name: longName,
          createdAt: DateTime(2024, 1, 15, 13, 0, 0),
        );

        // Act
        final encoded = codec.encode(metadata);
        final decoded = codec.decode(encoded);

        // Assert
        expect(decoded, isNotNull);
        expect(decoded!.name.length, longName.length);
        expect(decoded.name, longName);
      });

      test('should preserve precise timestamp', () {
        // Arrange
        final timestamp = DateTime(2024, 1, 15, 10, 30, 45, 123, 456);
        final metadata = ChannelMetadata(
          name: 'Precise Time',
          createdAt: timestamp,
        );

        // Act
        final encoded = codec.encode(metadata);
        final decoded = codec.decode(encoded);

        // Assert
        expect(decoded, isNotNull);
        expect(decoded!.createdAt, timestamp);
      });
    });

    group('decode error handling', () {
      test('should return null for invalid JSON', () {
        // Arrange
        final invalidBytes = Uint8List.fromList(utf8.encode('not json'));

        // Act
        final decoded = codec.decode(invalidBytes);

        // Assert
        expect(decoded, isNull);
      });

      test('should return null for wrong type discriminator', () {
        // Arrange
        final wrongType = {
          'type': 'message', // Wrong type
          'name': 'General',
          'createdAt': DateTime.now().toIso8601String(),
        };
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(wrongType)));

        // Act
        final decoded = codec.decode(bytes);

        // Assert
        expect(decoded, isNull);
      });

      test('should return null for missing required fields', () {
        // Arrange
        final missingField = {
          'type': 'metadata',
          // Missing 'name' field
          'createdAt': DateTime.now().toIso8601String(),
        };
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(missingField)));

        // Act
        final decoded = codec.decode(bytes);

        // Assert
        expect(decoded, isNull);
      });

      test('should return null for invalid date format', () {
        // Arrange
        final invalidDate = {
          'type': 'metadata',
          'name': 'General',
          'createdAt': 'invalid-date',
        };
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(invalidDate)));

        // Act
        final decoded = codec.decode(bytes);

        // Assert
        expect(decoded, isNull);
      });

      test('should return null for empty bytes', () {
        // Arrange
        final emptyBytes = Uint8List(0);

        // Act
        final decoded = codec.decode(emptyBytes);

        // Assert
        expect(decoded, isNull);
      });

      test('should return null for non-UTF8 bytes', () {
        // Arrange
        final invalidUtf8 = Uint8List.fromList([0xFF, 0xFE, 0xFD]);

        // Act
        final decoded = codec.decode(invalidUtf8);

        // Assert
        expect(decoded, isNull);
      });

      test('should return null for wrong field types', () {
        // Arrange
        final wrongTypes = {
          'type': 'metadata',
          'name': 123, // Should be string
          'createdAt': DateTime.now().toIso8601String(),
        };
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(wrongTypes)));

        // Act
        final decoded = codec.decode(bytes);

        // Assert
        expect(decoded, isNull);
      });
    });

    group('wire format', () {
      test('should produce valid UTF-8 JSON', () {
        // Arrange
        final metadata = ChannelMetadata(
          name: 'General',
          createdAt: DateTime(2024, 1, 15, 10, 30, 0),
        );

        // Act
        final encoded = codec.encode(metadata);
        final jsonStr = utf8.decode(encoded);
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;

        // Assert
        expect(json['type'], 'metadata');
        expect(json['name'], 'General');
        expect(json['createdAt'], '2024-01-15T10:30:00.000');
      });
    });
  });
}
