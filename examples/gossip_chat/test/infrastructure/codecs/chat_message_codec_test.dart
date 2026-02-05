import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_chat/domain/entities/chat_message.dart';
import 'package:gossip_chat/infrastructure/codecs/chat_message_codec.dart';

void main() {
  group('ChatMessageCodec', () {
    late ChatMessageCodec codec;

    setUp(() {
      codec = const ChatMessageCodec();
    });

    group('encode/decode roundtrip', () {
      test('should encode and decode a chat message successfully', () {
        // Arrange
        final message = ChatMessage(
          id: 'msg-123',
          text: 'Hello, World!',
          senderName: 'Alice',
          senderNode: NodeId('node-alice'),
          sentAt: DateTime(2024, 1, 15, 10, 30, 0),
        );

        // Act
        final encoded = codec.encode(message);
        final decoded = codec.decode(encoded);

        // Assert
        expect(decoded, isNotNull);
        expect(decoded!.id, message.id);
        expect(decoded.text, message.text);
        expect(decoded.senderName, message.senderName);
        expect(decoded.senderNode, message.senderNode);
        expect(decoded.sentAt, message.sentAt);
      });

      test('should handle empty text', () {
        // Arrange
        final message = ChatMessage(
          id: 'msg-empty',
          text: '',
          senderName: 'Bob',
          senderNode: NodeId('node-bob'),
          sentAt: DateTime(2024, 1, 15, 11, 0, 0),
        );

        // Act
        final encoded = codec.encode(message);
        final decoded = codec.decode(encoded);

        // Assert
        expect(decoded, isNotNull);
        expect(decoded!.text, '');
      });

      test('should handle special characters in text', () {
        // Arrange
        final message = ChatMessage(
          id: 'msg-special',
          text: 'Special chars: 你好 🎉 \n\t"quotes"',
          senderName: 'Charlie',
          senderNode: NodeId('node-charlie'),
          sentAt: DateTime(2024, 1, 15, 12, 0, 0),
        );

        // Act
        final encoded = codec.encode(message);
        final decoded = codec.decode(encoded);

        // Assert
        expect(decoded, isNotNull);
        expect(decoded!.text, message.text);
      });

      test('should handle long text', () {
        // Arrange
        final longText = 'A' * 1000;
        final message = ChatMessage(
          id: 'msg-long',
          text: longText,
          senderName: 'Dave',
          senderNode: NodeId('node-dave'),
          sentAt: DateTime(2024, 1, 15, 13, 0, 0),
        );

        // Act
        final encoded = codec.encode(message);
        final decoded = codec.decode(encoded);

        // Assert
        expect(decoded, isNotNull);
        expect(decoded!.text.length, 1000);
        expect(decoded.text, longText);
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
          'type': 'typing', // Wrong type
          'id': 'msg-123',
          'text': 'Hello',
          'senderName': 'Alice',
          'senderNode': 'node-alice',
          'sentAt': DateTime.now().toIso8601String(),
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
          'type': 'message',
          'id': 'msg-123',
          // Missing 'text' field
          'senderName': 'Alice',
          'senderNode': 'node-alice',
          'sentAt': DateTime.now().toIso8601String(),
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
          'type': 'message',
          'id': 'msg-123',
          'text': 'Hello',
          'senderName': 'Alice',
          'senderNode': 'node-alice',
          'sentAt': 'not-a-date',
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
    });

    group('wire format', () {
      test('should produce valid UTF-8 JSON', () {
        // Arrange
        final message = ChatMessage(
          id: 'msg-123',
          text: 'Test message',
          senderName: 'Alice',
          senderNode: NodeId('node-alice'),
          sentAt: DateTime(2024, 1, 15, 10, 30, 0),
        );

        // Act
        final encoded = codec.encode(message);
        final jsonStr = utf8.decode(encoded);
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;

        // Assert
        expect(json['type'], 'message');
        expect(json['id'], 'msg-123');
        expect(json['text'], 'Test message');
        expect(json['senderName'], 'Alice');
        expect(json['senderNode'], 'node-alice');
        expect(json['sentAt'], '2024-01-15T10:30:00.000');
      });
    });
  });
}
