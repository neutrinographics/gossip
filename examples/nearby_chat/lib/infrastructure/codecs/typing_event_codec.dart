import 'dart:convert';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

import '../../domain/entities/typing_event.dart';

/// Codec for encoding/decoding [TypingEvent] to/from bytes.
///
/// Wire format: UTF-8 encoded JSON with type discriminator.
class TypingEventCodec {
  const TypingEventCodec();

  static const _type = 'typing';

  /// Encodes a [TypingEvent] to bytes for storage in gossip entries.
  Uint8List encode(TypingEvent event) {
    final json = {
      'type': _type,
      'senderNode': event.senderNode.value,
      'senderName': event.senderName,
      'isTyping': event.isTyping,
      'timestamp': event.timestamp.toIso8601String(),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  /// Decodes bytes to a [TypingEvent].
  ///
  /// Returns `null` if the bytes are not a valid typing event.
  TypingEvent? decode(Uint8List bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (json['type'] != _type) return null;
      return TypingEvent(
        senderNode: NodeId(json['senderNode'] as String),
        senderName: json['senderName'] as String,
        isTyping: json['isTyping'] as bool,
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}
