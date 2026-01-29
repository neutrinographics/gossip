import 'package:gossip/gossip.dart' as gossip;

/// UI state for a chat message.
class MessageState {
  final String id;
  final String text;
  final String senderName;
  final gossip.NodeId senderNode;
  final DateTime sentAt;
  final bool isLocal;

  const MessageState({
    required this.id,
    required this.text,
    required this.senderName,
    required this.senderNode,
    required this.sentAt,
    required this.isLocal,
  });
}
