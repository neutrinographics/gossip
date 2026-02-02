import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gossip/gossip.dart';

import '../../domain/entities/chat_message.dart';

/// Codec for encoding/decoding [ChatMessage] to/from bytes.
///
/// Wire format: UTF-8 encoded JSON with type discriminator.
class ChatMessageCodec {
  const ChatMessageCodec();

  static const _type = 'message';

  /// Encodes a [ChatMessage] to bytes for storage in gossip entries.
  Uint8List encode(ChatMessage message) {
    final json = {
      'type': _type,
      'id': message.id,
      'text': message.text,
      'senderName': message.senderName,
      'senderNode': message.senderNode.value,
      'sentAt': message.sentAt.toIso8601String(),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  /// Decodes bytes to a [ChatMessage].
  ///
  /// Returns `null` if the bytes are not a valid chat message.
  ChatMessage? decode(Uint8List bytes) {
    if (bytes.isEmpty) return null;

    // Decode UTF-8
    final String jsonStr;
    try {
      jsonStr = utf8.decode(bytes);
    } on FormatException catch (e) {
      debugPrint('ChatMessageCodec: Invalid UTF-8 encoding: $e');
      return null;
    }

    // Parse JSON
    final Object? parsed;
    try {
      parsed = jsonDecode(jsonStr);
    } on FormatException catch (e) {
      debugPrint('ChatMessageCodec: Invalid JSON: $e');
      return null;
    }

    if (parsed is! Map<String, dynamic>) {
      debugPrint(
        'ChatMessageCodec: Expected JSON object, got ${parsed.runtimeType}',
      );
      return null;
    }

    // Check type discriminator
    if (parsed['type'] != _type) return null;

    // Extract fields with validation
    try {
      return ChatMessage(
        id: parsed['id'] as String,
        text: parsed['text'] as String,
        senderName: parsed['senderName'] as String,
        senderNode: NodeId(parsed['senderNode'] as String),
        sentAt: DateTime.parse(parsed['sentAt'] as String),
      );
    } on TypeError catch (e) {
      debugPrint('ChatMessageCodec: Missing or invalid field type: $e');
      return null;
    } on FormatException catch (e) {
      debugPrint('ChatMessageCodec: Invalid date format: $e');
      return null;
    }
  }
}
