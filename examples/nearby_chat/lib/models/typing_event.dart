import 'dart:convert';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

/// A typing indicator event stored in the presence stream.
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

  Map<String, dynamic> toJson() => {
    'type': 'typing',
    'senderNode': senderNode.value,
    'senderName': senderName,
    'isTyping': isTyping,
    'timestamp': timestamp.toIso8601String(),
  };

  factory TypingEvent.fromJson(Map<String, dynamic> json) => TypingEvent(
    senderNode: NodeId(json['senderNode'] as String),
    senderName: json['senderName'] as String,
    isTyping: json['isTyping'] as bool,
    timestamp: DateTime.parse(json['timestamp'] as String),
  );

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static TypingEvent? decode(Uint8List bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (json['type'] != 'typing') return null;
      return TypingEvent.fromJson(json);
    } catch (_) {
      return null;
    }
  }
}
