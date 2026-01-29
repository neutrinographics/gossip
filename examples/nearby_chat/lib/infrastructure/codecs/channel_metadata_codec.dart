import 'dart:convert';
import 'dart:typed_data';

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
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (json['type'] != _type) return null;
      return ChannelMetadata(
        name: json['name'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}
