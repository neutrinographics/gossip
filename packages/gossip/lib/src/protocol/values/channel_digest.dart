import 'package:meta/meta.dart';
import '../../domain/value_objects/channel_id.dart';
import 'stream_digest.dart';

/// Compact summary of an entire channel's synchronization state.
///
/// [ChannelDigest] aggregates the sync state of all streams within a channel.
/// It contains a [StreamDigest] for each stream, providing a complete picture
/// of the channel's state in a compact, wire-transmittable form.
///
/// Peers exchange channel digests during anti-entropy to:
/// - Identify which streams have diverged between peers
/// - Determine which streams need synchronization
/// - Avoid transmitting data for already-synchronized streams
///
/// ## Structure
/// A channel with N streams produces a digest containing:
/// - 1 channel ID (UUID ~36 bytes)
/// - N stream digests (each ~10-100 bytes)
/// - Total: typically 100-1000 bytes for a channel with several streams
///
/// This compact representation enables efficient gossip rounds without
/// overwhelming the network with full entry transmission.
@immutable
class ChannelDigest {
  /// The channel being summarized.
  final ChannelId channelId;

  /// Digests for each stream in the channel.
  ///
  /// Each digest contains a version vector summarizing that stream's
  /// sync state. Empty if the channel has no streams.
  final List<StreamDigest> streams;

  const ChannelDigest({required this.channelId, required this.streams});

  @override
  bool operator ==(Object other) {
    if (other is! ChannelDigest) return false;
    if (other.channelId != channelId) return false;
    if (other.streams.length != streams.length) return false;
    for (var i = 0; i < streams.length; i++) {
      if (other.streams[i] != streams[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var hash = channelId.hashCode;
    for (final stream in streams) {
      hash ^= stream.hashCode;
    }
    return hash;
  }

  @override
  String toString() => 'ChannelDigest($channelId, ${streams.length} streams)';
}
