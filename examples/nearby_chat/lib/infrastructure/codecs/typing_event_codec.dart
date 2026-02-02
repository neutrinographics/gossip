import 'dart:convert';

import 'package:flutter/foundation.dart';
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
    if (bytes.isEmpty) return null;

    // Decode UTF-8
    final String jsonStr;
    try {
      jsonStr = utf8.decode(bytes);
    } on FormatException catch (e) {
      debugPrint('TypingEventCodec: Invalid UTF-8 encoding: $e');
      return null;
    }

    // Parse JSON
    final Object? parsed;
    try {
      parsed = jsonDecode(jsonStr);
    } on FormatException catch (e) {
      debugPrint('TypingEventCodec: Invalid JSON: $e');
      return null;
    }

    if (parsed is! Map<String, dynamic>) {
      debugPrint(
        'TypingEventCodec: Expected JSON object, got ${parsed.runtimeType}',
      );
      return null;
    }

    // Check type discriminator
    if (parsed['type'] != _type) return null;

    // Extract fields with validation
    try {
      return TypingEvent(
        senderNode: NodeId(parsed['senderNode'] as String),
        senderName: parsed['senderName'] as String,
        isTyping: parsed['isTyping'] as bool,
        timestamp: DateTime.parse(parsed['timestamp'] as String),
      );
    } on TypeError catch (e) {
      debugPrint('TypingEventCodec: Missing or invalid field type: $e');
      return null;
    } on FormatException catch (e) {
      debugPrint('TypingEventCodec: Invalid date format: $e');
      return null;
    }
  }
}
