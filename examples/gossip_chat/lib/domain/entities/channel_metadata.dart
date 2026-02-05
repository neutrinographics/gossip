/// Metadata for a channel.
///
/// This is a pure domain entity with no serialization logic.
/// Use [ChannelMetadataCodec] for encoding/decoding.
class ChannelMetadata {
  final String name;
  final DateTime createdAt;

  const ChannelMetadata({required this.name, required this.createdAt});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChannelMetadata &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(name, createdAt);

  @override
  String toString() => 'ChannelMetadata(name: $name, createdAt: $createdAt)';
}
