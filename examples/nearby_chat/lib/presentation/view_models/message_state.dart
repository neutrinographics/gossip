import 'package:gossip/gossip.dart' as gossip;

/// Delivery status for a message.
enum MessageDeliveryStatus {
  /// Message is being sent.
  sending,

  /// Message has been sent successfully.
  sent,

  /// Message delivery failed.
  failed,
}

/// UI state for a chat message.
class MessageState {
  final String id;
  final String text;
  final String senderName;
  final gossip.NodeId senderNode;
  final DateTime sentAt;
  final bool isLocal;
  final MessageDeliveryStatus deliveryStatus;

  const MessageState({
    required this.id,
    required this.text,
    required this.senderName,
    required this.senderNode,
    required this.sentAt,
    required this.isLocal,
    this.deliveryStatus = MessageDeliveryStatus.sent,
  });

  MessageState copyWith({
    String? id,
    String? text,
    String? senderName,
    gossip.NodeId? senderNode,
    DateTime? sentAt,
    bool? isLocal,
    MessageDeliveryStatus? deliveryStatus,
  }) {
    return MessageState(
      id: id ?? this.id,
      text: text ?? this.text,
      senderName: senderName ?? this.senderName,
      senderNode: senderNode ?? this.senderNode,
      sentAt: sentAt ?? this.sentAt,
      isLocal: isLocal ?? this.isLocal,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
    );
  }
}
