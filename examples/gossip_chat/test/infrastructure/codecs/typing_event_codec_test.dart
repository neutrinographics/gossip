import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_chat/domain/entities/typing_event.dart';
import 'package:gossip_chat/infrastructure/codecs/typing_event_codec.dart';

void main() {
  group('TypingEventCodec', () {
    late TypingEventCodec codec;

    setUp(() {
      codec = const TypingEventCodec();
    });

    group('encode/decode roundtrip', () {
      test('should encode and decode a typing event successfully', () {
        // Arrange
        final event = TypingEvent(
          senderNode: NodeId('node-alice'),
          senderName: 'Alice',
          isTyping: true,
          timestamp: DateTime(2024, 1, 15, 10, 30, 0),
        );

        // Act
        final encoded = codec.encode(event);
        final decoded = codec.decode(encoded);

        // Assert
        expect(decoded, isNotNull);
        expect(decoded!.senderNode, event.senderNode);
        expect(decoded.senderName, event.senderName);
        expect(decoded.isTyping, event.isTyping);
        expect(decoded.timestamp, event.timestamp);
      });

      test('should handle isTyping false', () {
        // Arrange
        final event = TypingEvent(
          senderNode: NodeId('node-bob'),
          senderName: 'Bob',
          isTyping: false,
          timestamp: DateTime(2024, 1, 15, 11, 0, 0),
        );

        // Act
        final encoded = codec.encode(event);
        final decoded = codec.decode(encoded);

        // Assert
        expect(decoded, isNotNull);
        expect(decoded!.isTyping, false);
      });

      test('should handle special characters in senderName', () {
        // Arrange
        final event = TypingEvent(
          senderNode: NodeId('node-special'),
          senderName: 'User 你好 🎉',
          isTyping: true,
          timestamp: DateTime(2024, 1, 15, 12, 0, 0),
        );

        // Act
        final encoded = codec.encode(event);
        final decoded = codec.decode(encoded);

        // Assert
        expect(decoded, isNotNull);
        expect(decoded!.senderName, event.senderName);
      });

      test('should preserve precise timestamp', () {
        // Arrange
        final timestamp = DateTime(2024, 1, 15, 10, 30, 45, 123);
        final event = TypingEvent(
          senderNode: NodeId('node-time'),
          senderName: 'TimeUser',
          isTyping: true,
          timestamp: timestamp,
        );

        // Act
        final encoded = codec.encode(event);
        final decoded = codec.decode(encoded);

        // Assert
        expect(decoded, isNotNull);
        expect(decoded!.timestamp, timestamp);
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
          'senderNode': 'node-alice',
          'senderName': 'Alice',
          'isTyping': true,
          'timestamp': DateTime.now().toIso8601String(),
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
          'type': 'typing',
          'senderNode': 'node-alice',
          // Missing 'senderName' field
          'isTyping': true,
          'timestamp': DateTime.now().toIso8601String(),
        };
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(missingField)));

        // Act
        final decoded = codec.decode(bytes);

        // Assert
        expect(decoded, isNull);
      });

      test('should return null for invalid boolean type', () {
        // Arrange
        final invalidBool = {
          'type': 'typing',
          'senderNode': 'node-alice',
          'senderName': 'Alice',
          'isTyping': 'yes', // Should be boolean
          'timestamp': DateTime.now().toIso8601String(),
        };
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(invalidBool)));

        // Act
        final decoded = codec.decode(bytes);

        // Assert
        expect(decoded, isNull);
      });

      test('should return null for invalid timestamp format', () {
        // Arrange
        final invalidTimestamp = {
          'type': 'typing',
          'senderNode': 'node-alice',
          'senderName': 'Alice',
          'isTyping': true,
          'timestamp': 'not-a-timestamp',
        };
        final bytes = Uint8List.fromList(
          utf8.encode(jsonEncode(invalidTimestamp)),
        );

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
    });

    group('wire format', () {
      test('should produce valid UTF-8 JSON with correct type', () {
        // Arrange
        final event = TypingEvent(
          senderNode: NodeId('node-alice'),
          senderName: 'Alice',
          isTyping: true,
          timestamp: DateTime(2024, 1, 15, 10, 30, 0),
        );

        // Act
        final encoded = codec.encode(event);
        final jsonStr = utf8.decode(encoded);
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;

        // Assert
        expect(json['type'], 'typing');
        expect(json['senderNode'], 'node-alice');
        expect(json['senderName'], 'Alice');
        expect(json['isTyping'], true);
        expect(json['timestamp'], '2024-01-15T10:30:00.000');
      });

      test('should use compact JSON representation', () {
        // Arrange
        final event = TypingEvent(
          senderNode: NodeId('node-test'),
          senderName: 'Test',
          isTyping: false,
          timestamp: DateTime(2024, 1, 15, 10, 30, 0),
        );

        // Act
        final encoded = codec.encode(event);

        // Assert - JSON should be compact (no extra whitespace)
        final jsonStr = utf8.decode(encoded);
        expect(jsonStr, isNot(contains('  '))); // No double spaces
        expect(jsonStr, isNot(contains('\n'))); // No newlines
      });
    });
  });
}
