import 'dart:convert';
import 'dart:typed_data';

/// Metadata for a channel stored in the metadata stream.
class ChannelMetadata {
  final String name;
  final DateTime createdAt;

  const ChannelMetadata({required this.name, required this.createdAt});

  Map<String, dynamic> toJson() => {
    'type': 'metadata',
    'name': name,
    'createdAt': createdAt.toIso8601String(),
  };

  factory ChannelMetadata.fromJson(Map<String, dynamic> json) =>
      ChannelMetadata(
        name: json['name'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static ChannelMetadata? decode(Uint8List bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (json['type'] != 'metadata') return null;
      return ChannelMetadata.fromJson(json);
    } catch (_) {
      return null;
    }
  }
}
