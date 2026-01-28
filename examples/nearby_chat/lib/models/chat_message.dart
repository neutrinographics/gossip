import 'dart:convert';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

/// A chat message payload stored in gossip entries.
class ChatMessage {
  final String id;
  final String text;
  final String senderName;
  final NodeId senderNode;
  final DateTime sentAt;

  const ChatMessage({
    required this.id,
    required this.text,
    required this.senderName,
    required this.senderNode,
    required this.sentAt,
  });

  Map<String, dynamic> toJson() => {
    'type': 'message',
    'id': id,
    'text': text,
    'senderName': senderName,
    'senderNode': senderNode.value,
    'sentAt': sentAt.toIso8601String(),
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String,
    text: json['text'] as String,
    senderName: json['senderName'] as String,
    senderNode: NodeId(json['senderNode'] as String),
    sentAt: DateTime.parse(json['sentAt'] as String),
  );

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static ChatMessage? decode(Uint8List bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (json['type'] != 'message') return null;
      return ChatMessage.fromJson(json);
    } catch (_) {
      return null;
    }
  }
}
