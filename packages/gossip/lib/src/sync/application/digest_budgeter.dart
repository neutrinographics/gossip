import 'package:gossip/src/shared/domain/interfaces/message_codec.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/application/digest_rotation.dart';
import 'package:gossip/src/sync/application/digest_window.dart';
import 'package:gossip/src/sync/application/peer_rotation.dart';
import 'package:gossip/src/sync/application/recency.dart';
import 'package:gossip/src/sync/application/rotation_key.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/services/digest_scoping.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';

/// A single stream digest that alone exceeds [DigestBudgeter]'s byte
/// budget — it can never be sent, no matter how the window is chosen.
///
/// Carries enough for the caller (`GossipEngine`) to render a diagnostic
/// identifying the offending stream and its approximate encoded cost,
/// without the budgeter depending on the engine's error type.
class OversizedDigest {
  /// The channel the oversized stream belongs to.
  final ChannelId channel;

  /// The stream whose digest alone exceeds the budget.
  final StreamId streamId;

  /// The digest's encoded cost in bytes: what it adds to a request that
  /// carried nothing else, measured through the codec.
  final int cost;

  const OversizedDigest({
    required this.channel,
    required this.streamId,
    required this.cost,
  });
}

/// A request fitted to one message: what goes, what was named instead of
/// digested, and what can never go.
class FittedRequest {
  final List<ChannelDigest> digests;
  final List<ChannelId> announced;
  final List<OversizedDigest> oversized;

  /// An announcement whose cost alone exceeds the announce budget: skipped and
  /// passed on, so it blocks nothing. An announcement that merely lacks room
  /// this round (the digests left less than it costs) is not reported.
  final List<ChannelId> unannounceable;

  const FittedRequest({
    required this.digests,
    required this.announced,
    required this.oversized,
    required this.unannounceable,
  });
}

/// A response carries digests only, so it has nothing to announce.
class FittedResponse {
  final List<ChannelDigest> digests;
  final List<OversizedDigest> oversized;

  const FittedResponse({required this.digests, required this.oversized});
}

/// Fits digest lists to bytes and rotates what does not fit — the Kotlin
/// twin's `DigestBudgeter`, with sizes measured through the codec seam and
/// the per-peer rotation (each item's last send, ordering every window
/// least-recently-sent first) kept in a plain field: the engine runs on one
/// isolate (ADR-001), so no cell guards it.
///
/// Digests are fitted first under the message budget; announcements then fill
/// the announce budget within the room the digests left, and are not spent at
/// all when no room is left. Every cost is an item encoded alone, so a stream
/// is charged its channel's envelope even when it shares the channel with a
/// neighbour — never an underestimate. The separators between selected items
/// are not in those costs: [DigestWindow] owns them.
class DigestBudgeter {
  DigestBudgeter({
    required MessageCodec codec,
    required NodeId localNode,
    required this.maxMessageBytes,
    required this.announceBudgetBytes,
  }) : _codec = codec,
       _localNode = localNode,
       _base = codec
           .encode(DigestRequest(sender: localNode, digests: const []))
           .length;

  final MessageCodec _codec;
  final NodeId _localNode;
  final int _base;

  /// The transport's limit on one encoded message.
  final int maxMessageBytes;

  /// The most a request may spend naming channels it does not digest, so a
  /// large channel list cannot crowd digests out.
  final int announceBudgetBytes;

  DigestRotation _rotation = DigestRotation.initial;

  /// Fits a scoped request into one message: digests take what they need
  /// first, since they carry the data a peer is waiting on, and announcements
  /// share only what is left, capped by the announce budget. When the budget,
  /// or the room left, cannot hold even one announcement, none is sent or
  /// reported and nothing is stamped as sent, so no channel is skipped unseen.
  FittedRequest fitRequest(ScopedDigests scoped, NodeId peer) {
    final digests = _fitDigests(
      scoped.digests,
      peer,
      (r) => r.request,
      (r, recency) => r.copyWith(request: recency),
    );
    final (announced, unannounceable) = _fitAnnouncements(
      scoped.announced,
      maxMessageBytes - _base - digests.bytes,
      digests.digests.isNotEmpty,
      peer,
    );
    return FittedRequest(
      digests: digests.digests,
      announced: announced,
      oversized: digests.oversized,
      unannounceable: unannounceable,
    );
  }

  /// Response to [peer]: digests only, under the message budget least
  /// recently sent first.
  FittedResponse fitResponse(List<ChannelDigest> digests, NodeId peer) {
    final fitted = _fitDigests(
      digests,
      peer,
      (r) => r.response,
      (r, recency) => r.copyWith(response: recency),
    );
    return FittedResponse(digests: fitted.digests, oversized: fitted.oversized);
  }

  /// Forgets [peer]'s rotation, so a re-added peer is offered every item
  /// again from the start.
  void forget(NodeId peer) {
    _rotation = _rotation.forget(peer);
  }

  /// Returns every peer's rotation to the start.
  void reset() {
    _rotation = DigestRotation.initial;
  }

  _DigestsFitted _fitDigests(
    List<ChannelDigest> digests,
    NodeId peer,
    Recency Function(PeerRotation) recencyOf,
    PeerRotation Function(PeerRotation, Recency) withRecency,
  ) {
    // A list that fits whole is sent whole and stamps nothing: recency only
    // decides what goes first when something must wait, so a round that makes
    // nothing wait leaves the order as it was.
    final wholeSize = _encodedSize(digests);
    if (wholeSize <= maxMessageBytes) {
      return _DigestsFitted(digests, const [], wholeSize - _base);
    }

    final items = <_Item>[
      for (final d in digests)
        if (d.streams.isEmpty)
          _EmptyChannelItem(d.channelId, _encodedSize([d]) - _base)
        else
          for (final s in d.streams)
            _StreamItem(
              d.channelId,
              s,
              _encodedSize([
                    ChannelDigest(channelId: d.channelId, streams: [s]),
                  ]) -
                  _base,
            ),
    ];
    final window = DigestWindow.select<_Item>(
      items: items,
      costs: [for (final i in items) i.cost],
      keys: [for (final i in items) i.key],
      recency: recencyOf(_rotation.of(peer)),
      budget: maxMessageBytes - _base,
    );
    _stamp(
      peer,
      [for (final i in window.selected) i.key],
      recencyOf,
      withRecency,
    );

    // Only a stream can be reported: an empty channel digest is a few dozen
    // bytes, so it exceeds a budget only when the budget cannot hold any
    // message worth sending, and then it has no stream to name.
    final oversized = [
      for (final i in window.oversized)
        if (i is _StreamItem)
          OversizedDigest(
            channel: i.channel,
            streamId: i.stream.streamId,
            cost: i.cost,
          ),
    ];
    return _DigestsFitted(
      _regroup(window.selected),
      oversized,
      window.usedBytes,
    );
  }

  /// Announcements follow the digests in the same wire array, so when any
  /// digest was selected the first announcement is joined to it by a
  /// separator the window cannot see. One byte is taken off the budget for
  /// it; the window then charges only the separators between the
  /// announcements themselves.
  (List<ChannelId>, List<ChannelId>) _fitAnnouncements(
    List<ChannelId> announced,
    int room,
    bool followsDigests,
    NodeId peer,
  ) {
    final spendable = announceBudgetBytes < room ? announceBudgetBytes : room;
    final budget = spendable - (followsDigests ? 1 : 0);
    if (budget <= 0 || announced.isEmpty) return (const [], const []);

    final costs = [for (final id in announced) _announceCost(id)];
    // A budget no announcement fits is a configuration or a squeeze, not a
    // fault of any one channel: spend nothing, report nothing, move nothing.
    if (costs.reduce((a, b) => a < b ? a : b) > budget) {
      return (const [], const []);
    }
    final window = DigestWindow.select<ChannelId>(
      items: announced,
      costs: costs,
      keys: [for (final id in announced) RotationKey(id)],
      recency: _rotation.of(peer).announce,
      budget: budget,
    );
    _stamp(
      peer,
      [for (final id in window.selected) RotationKey(id)],
      (r) => r.announce,
      (r, recency) => r.copyWith(announce: recency),
    );
    // With at least one announcement fitting, one over its own budget is
    // unannounceable; one that merely lacked room this round is not reported.
    final unannounceable = [
      for (final id in window.oversized)
        if (_announceCost(id) > announceBudgetBytes) id,
    ];
    return (window.selected, unannounceable);
  }

  void _stamp(
    NodeId peer,
    List<RotationKey> sent,
    Recency Function(PeerRotation) recencyOf,
    PeerRotation Function(PeerRotation, Recency) withRecency,
  ) {
    final mine = _rotation.of(peer);
    _rotation = _rotation.withPeer(
      peer,
      withRecency(mine, recencyOf(mine).stamp(sent)),
    );
  }

  List<ChannelDigest> _regroup(List<_Item> selected) {
    final byChannel = <ChannelId, List<StreamDigest>>{};
    for (final item in selected) {
      final streams = byChannel.putIfAbsent(item.channel, () => []);
      if (item is _StreamItem) streams.add(item.stream);
    }
    return [
      for (final e in byChannel.entries)
        ChannelDigest(channelId: e.key, streams: e.value),
    ];
  }

  int _encodedSize(List<ChannelDigest> digests) =>
      _codec.encode(DigestRequest(sender: _localNode, digests: digests)).length;

  int _announceCost(ChannelId id) =>
      _codec
          .encode(
            DigestRequest(
              sender: _localNode,
              digests: const [],
              announced: [id],
            ),
          )
          .length -
      _base;
}

class _DigestsFitted {
  final List<ChannelDigest> digests;
  final List<OversizedDigest> oversized;
  final int bytes;

  const _DigestsFitted(this.digests, this.oversized, this.bytes);
}

/// What the window selects among. An empty channel digest is an item of its
/// own, not nothing: it is the answer that tells an announcer we hold a
/// channel with no streams yet, and fitting must not erase it.
sealed class _Item {
  final ChannelId channel;
  final int cost;

  const _Item(this.channel, this.cost);

  RotationKey get key;
}

class _StreamItem extends _Item {
  final StreamDigest stream;

  const _StreamItem(super.channel, this.stream, super.cost);

  @override
  RotationKey get key => RotationKey(channel, stream.streamId);
}

class _EmptyChannelItem extends _Item {
  const _EmptyChannelItem(super.channel, super.cost);

  @override
  RotationKey get key => RotationKey(channel);
}
