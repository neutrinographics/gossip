import 'package:gossip/gossip.dart';

/// A typing indicator event in a channel's presence stream.
///
/// This is a pure domain entity with no serialization logic.
/// Use [TypingEventCodec] for encoding/decoding.
class TypingEvent {
  final NodeId senderNode;
  final String senderName;
  final bool isTyping;
  final DateTime timestamp;

  const TypingEvent({
    required this.senderNode,
    required this.senderName,
    required this.isTyping,
    required this.timestamp,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TypingEvent &&
          runtimeType == other.runtimeType &&
          senderNode == other.senderNode &&
          timestamp == other.timestamp;

  @override
  int get hashCode => Object.hash(senderNode, timestamp);

  @override
  String toString() => 'TypingEvent(sender: $senderName, isTyping: $isTyping)';
}
