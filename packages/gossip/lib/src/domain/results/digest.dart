import '../value_objects/channel_id.dart';
import '../value_objects/stream_id.dart';
import '../value_objects/version_vector.dart';

/// Digest types for sync protocol.

class StreamDigest {
  final VersionVector version;

  const StreamDigest(this.version);

  @override
  bool operator ==(Object other) =>
      other is StreamDigest && other.version == version;

  @override
  int get hashCode => version.hashCode;
}

class ChannelDigest {
  final ChannelId channelId;
  final Map<StreamId, StreamDigest> streams;

  const ChannelDigest(this.channelId, this.streams);

  @override
  bool operator ==(Object other) =>
      other is ChannelDigest &&
      other.channelId == channelId &&
      _mapsEqual(other.streams, streams);

  @override
  int get hashCode => Object.hash(channelId, streams);

  bool _mapsEqual(Map a, Map b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }
}

class BatchedDigest {
  final Map<ChannelId, ChannelDigest> channels;

  const BatchedDigest(this.channels);

  bool get isEmpty => channels.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is BatchedDigest && _mapsEqual(other.channels, channels);

  @override
  int get hashCode => channels.hashCode;

  bool _mapsEqual(Map a, Map b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }
}
