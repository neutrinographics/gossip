import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';

/// The rule of a digest response: answer what the request named and nothing
/// else.
///
/// An announced channel is answered with our whole digest for it (no
/// dominance filter is possible without the requester's vectors); a digested
/// channel with the named streams we hold whose vector the requester's does
/// not already dominate, and it is absent when none survives. A channel both
/// announced and digested is answered as digested, once. Channel order is the
/// request's; within a channel the streams follow our digest's order.
///
/// Pure: `ours` is our whole digest for each named channel we hold, gathered
/// by the caller; a channel in it that the request did not name never
/// appears in the answer.
abstract final class DigestAnswering {
  static List<ChannelDigest> answer(
    DigestRequest request,
    List<ChannelDigest> ours,
  ) {
    final byId = {for (final digest in ours) digest.channelId: digest};
    final result = <ChannelDigest>[];
    final answered = <ChannelId>{};

    for (final requested in request.digests) {
      final ourDigest = byId[requested.channelId];
      if (ourDigest == null) continue;
      answered.add(requested.channelId);

      final requestedByStream = <StreamId, StreamDigest>{};
      for (final stream in requested.streams) {
        requestedByStream.putIfAbsent(stream.streamId, () => stream);
      }
      final kept = <StreamDigest>[];
      for (final ourStream in ourDigest.streams) {
        final theirs = requestedByStream[ourStream.streamId];
        if (theirs == null) continue;
        if (!theirs.version.dominates(ourStream.version)) kept.add(ourStream);
      }

      if (kept.isNotEmpty) {
        result.add(
          ChannelDigest(channelId: requested.channelId, streams: kept),
        );
      }
    }

    for (final channelId in request.announced) {
      if (answered.contains(channelId)) continue;
      final ourDigest = byId[channelId];
      if (ourDigest != null) result.add(ourDigest);
    }

    return result;
  }
}
