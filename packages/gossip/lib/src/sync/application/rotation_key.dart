import 'package:meta/meta.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';

/// The identity of an item the budgeter can offer a peer: a stream digest is
/// (channel, stream); an empty channel digest and an announcement are the
/// channel alone, with a null [stream]. Identity, not position, is what a
/// rotation remembers, because a position into a list that changes shape
/// points at a different item every time.
@immutable
class RotationKey {
  final ChannelId channel;
  final StreamId? stream;

  const RotationKey(this.channel, [this.stream]);

  @override
  bool operator ==(Object other) =>
      other is RotationKey &&
      other.channel == channel &&
      other.stream == stream;

  @override
  int get hashCode => Object.hash(channel, stream);

  @override
  String toString() => 'RotationKey($channel, $stream)';
}
