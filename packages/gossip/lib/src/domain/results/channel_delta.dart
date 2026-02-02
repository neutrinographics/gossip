import '../value_objects/channel_id.dart';
import '../value_objects/log_entry.dart';
import '../value_objects/stream_id.dart';

/// Delta containing entries a peer is missing.
class ChannelDelta {
  final ChannelId channelId;
  final Map<StreamId, List<LogEntry>> entries;

  const ChannelDelta(this.channelId, this.entries);

  int get totalEntries =>
      entries.values.fold(0, (sum, list) => sum + list.length);

  int get totalBytes => entries.values.fold(
    0,
    (sum, list) => sum + list.fold(0, (s, e) => s + e.sizeBytes),
  );

  @override
  bool operator ==(Object other) =>
      other is ChannelDelta &&
      other.channelId == channelId &&
      _mapsEqual(other.entries, entries);

  @override
  int get hashCode => Object.hash(channelId, entries);

  bool _mapsEqual(Map a, Map b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }
}
