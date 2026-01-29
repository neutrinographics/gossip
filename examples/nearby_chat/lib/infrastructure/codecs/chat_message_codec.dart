import 'dart:convert';
import 'dart:typed_data';

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
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (json['type'] != _type) return null;
      return ChatMessage(
        id: json['id'] as String,
        text: json['text'] as String,
        senderName: json['senderName'] as String,
        senderNode: NodeId(json['senderNode'] as String),
        sentAt: DateTime.parse(json['sentAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}
