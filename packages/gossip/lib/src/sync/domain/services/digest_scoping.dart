import 'package:meta/meta.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';

/// What a digest request carries once scoped: digests for the channels the
/// peer has shown it holds, announcements for the rest.
@immutable
class ScopedDigests {
  final List<ChannelDigest> digests;
  final List<ChannelId> announced;

  const ScopedDigests({required this.digests, required this.announced});
}

/// The rule of a digest request: a channel the peer has shown it holds gets
/// our digest; every other channel we hold gets an announcement.
///
/// Pure: takes digests and the peer's holdings, returns two lists in the
/// order given, consults nothing else and knows no byte — fitting is the
/// budgeter's.
abstract final class DigestScoping {
  /// [ours] is a digest for every channel we hold; [shown] is the channels
  /// this peer has shown it holds.
  static ScopedDigests scope(List<ChannelDigest> ours, Set<ChannelId> shown) {
    final digests = <ChannelDigest>[];
    final announced = <ChannelId>[];
    for (final digest in ours) {
      if (shown.contains(digest.channelId)) {
        digests.add(digest);
      } else {
        announced.add(digest.channelId);
      }
    }
    return ScopedDigests(digests: digests, announced: announced);
  }
}
