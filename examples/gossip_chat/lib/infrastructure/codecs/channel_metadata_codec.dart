import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../domain/entities/channel_metadata.dart';

/// Codec for encoding/decoding [ChannelMetadata] to/from bytes.
///
/// Wire format: UTF-8 encoded JSON with type discriminator.
class ChannelMetadataCodec {
  const ChannelMetadataCodec();

  static const _type = 'metadata';

  /// Encodes [ChannelMetadata] to bytes for storage in gossip entries.
  Uint8List encode(ChannelMetadata metadata) {
    final json = {
      'type': _type,
      'name': metadata.name,
      'createdAt': metadata.createdAt.toIso8601String(),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  /// Decodes bytes to [ChannelMetadata].
  ///
  /// Returns `null` if the bytes are not valid channel metadata.
  ChannelMetadata? decode(Uint8List bytes) {
    if (bytes.isEmpty) return null;

    // Decode UTF-8
    final String jsonStr;
    try {
      jsonStr = utf8.decode(bytes);
    } on FormatException catch (e) {
      debugPrint('ChannelMetadataCodec: Invalid UTF-8 encoding: $e');
      return null;
    }

    // Parse JSON
    final Object? parsed;
    try {
      parsed = jsonDecode(jsonStr);
    } on FormatException catch (e) {
      debugPrint('ChannelMetadataCodec: Invalid JSON: $e');
      return null;
    }

    if (parsed is! Map<String, dynamic>) {
      debugPrint(
        'ChannelMetadataCodec: Expected JSON object, got ${parsed.runtimeType}',
      );
      return null;
    }

    // Check type discriminator
    if (parsed['type'] != _type) return null;

    // Extract fields with validation
    try {
      return ChannelMetadata(
        name: parsed['name'] as String,
        createdAt: DateTime.parse(parsed['createdAt'] as String),
      );
    } on TypeError catch (e) {
      debugPrint('ChannelMetadataCodec: Missing or invalid field type: $e');
      return null;
    } on FormatException catch (e) {
      debugPrint('ChannelMetadataCodec: Invalid date format: $e');
      return null;
    }
  }
}
