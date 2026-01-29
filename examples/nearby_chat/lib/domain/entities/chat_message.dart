import 'package:gossip/gossip.dart';

/// A chat message in a channel.
///
/// This is a pure domain entity with no serialization logic.
/// Use [ChatMessageCodec] for encoding/decoding.
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ChatMessage(id: $id, text: $text, sender: $senderName)';
}
