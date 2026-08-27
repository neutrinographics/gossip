import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/domain/value_objects/stream_id.dart';
import 'package:gossip/src/sync/domain/messages/digest_request.dart';
import 'package:gossip/src/sync/domain/value_objects/channel_digest.dart';
import 'package:gossip/src/sync/domain/value_objects/stream_digest.dart';
import 'package:gossip/src/sync/infrastructure/sync_message_codec.dart';

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

  /// The digest's approximate encoded cost in bytes (conservative — see
  /// [DigestBudgeter]'s `_channelEnvelopeOverheadBytes`).
  final int cost;

  const OversizedDigest({
    required this.channel,
    required this.streamId,
    required this.cost,
  });
}

/// Owns `GossipEngine`'s byte-budgeted digest windowing: fitting a
/// digest request or response to the transport's `maxMessageBytes` limit by
/// selecting a round-robin-rotated subset of (channel, stream) digests when
/// the full set doesn't fit — instead of one oversized message the
/// transport can never send.
///
/// Two independent cursors, one per call site — [fitRequest]'s and
/// [fitResponse]'s — because they rotate through unrelated cadences: this
/// node's own request cadence vs. however often peers ask it to respond.
/// Sharing one cursor would let one side's advance silently skew the
/// other's coverage.
class DigestBudgeter {
  DigestBudgeter({
    required SyncMessageCodec codec,
    required NodeId localNode,
    required int maxMessageBytes,
  }) : _codec = codec,
       _localNode = localNode,
       _maxMessageBytes = maxMessageBytes;

  final SyncMessageCodec _codec;
  final NodeId _localNode;
  final int _maxMessageBytes;

  /// Round-robin cursor over the flattened (channel, stream) digest list.
  /// Used only when a full digest exceeds the transport budget: each round
  /// advertises a byte-budgeted window, and the cursor advances so every
  /// stream is covered across successive rounds (otherwise the streams past
  /// the truncation point would never sync).
  int _requestCursor = 0;

  /// Round-robin cursor for [fitResponse], independent of [_requestCursor]
  /// (the requester-side cursor).
  ///
  /// Without its own cursor, an over-budget response always fits starting
  /// at the same index, so it truncates the same tail every exchange — some
  /// streams are never advertised by this node as a responder, no matter how
  /// many times a peer asks. Advanced by [_fit]'s items-consumed return,
  /// same as the requester side.
  int _responseCursor = 0;

  /// Conservative per-item overhead budgeted for a channel's envelope
  /// (channelId field, structural JSON) in [_fit]'s cost estimate.
  /// Deliberately approximate — [SyncMessageCodec] owns the real encoded
  /// format; this only has to never underestimate it, so the budget check
  /// never lets an over-size message through.
  static const int _channelEnvelopeOverheadBytes = 40;

  /// Fits [all] (this node's full digest set) to the transport budget for a
  /// DigestRequest, using the request-side rotation cursor.
  ///
  /// Sends the full digest when it fits (the common case). When it doesn't,
  /// returns a byte-budgeted, round-robin-rotated subset of streams so no
  /// message is oversized and every stream is covered across rounds —
  /// instead of a giant message the transport can never carry.
  (List<ChannelDigest>, List<OversizedDigest>) fitRequest(
    List<ChannelDigest> all,
  ) {
    final full = DigestRequest(sender: _localNode, digests: all);
    if (_codec.encode(full).length <= _maxMessageBytes) {
      return (all, const []);
    }

    final flat = _flatten(all);
    final (digests, oversized, consumed) = _fit(flat, _requestCursor);
    if (flat.isNotEmpty) {
      _requestCursor = (_requestCursor + consumed) % flat.length;
    }
    return (digests, oversized);
  }

  /// Fits pre-flattened `(channel, stream digest)` pairs to the transport
  /// budget for a DigestResponse, using the response-side rotation cursor.
  ///
  /// Unlike [fitRequest], there is no full-fit fast path here: the caller
  /// has already scoped [flat] to exactly what the response needs to
  /// cover, and [_fit] naturally returns everything when it all fits.
  (List<ChannelDigest>, List<OversizedDigest>) fitResponse(
    List<({ChannelId channel, StreamDigest digest})> flat,
  ) {
    final (digests, oversized, consumed) = _fit(flat, _responseCursor);
    if (flat.isNotEmpty) {
      _responseCursor = (_responseCursor + consumed) % flat.length;
    }
    return (digests, oversized);
  }

  /// Flattens grouped channel digests into a `(channel, stream digest)` list
  /// for byte-budgeted selection.
  List<({ChannelId channel, StreamDigest digest})> _flatten(
    List<ChannelDigest> all,
  ) {
    final flat = <({ChannelId channel, StreamDigest digest})>[];
    for (final channelDigest in all) {
      for (final streamDigest in channelDigest.streams) {
        flat.add((channel: channelDigest.channelId, digest: streamDigest));
      }
    }
    return flat;
  }

  /// Selects the largest prefix of [flat] (starting at [startIndex],
  /// wrapping) whose encoded digest message fits [_maxMessageBytes],
  /// regrouped by channel. Returns the selected digests, any
  /// oversized-stream diagnostics, and the number of items consumed (for
  /// advancing the caller's rotation cursor).
  ///
  /// A single stream digest that alone exceeds the budget can never be
  /// sent; it is skipped and reported as an [OversizedDigest] rather than
  /// silently blocking the whole message every round.
  (List<ChannelDigest>, List<OversizedDigest>, int) _fit(
    List<({ChannelId channel, StreamDigest digest})> flat,
    int startIndex,
  ) {
    final n = flat.length;
    if (n == 0) {
      return (const <ChannelDigest>[], const <OversizedDigest>[], 0);
    }

    final base = _codec
        .encode(DigestRequest(sender: _localNode, digests: const []))
        .length;

    final selected = <ChannelId, List<StreamDigest>>{};
    final oversized = <OversizedDigest>[];
    var size = base;
    var consumed = 0;

    for (var i = 0; i < n; i++) {
      final item = flat[(startIndex + i) % n];
      // Conservative cost: the stream digest plus a full channel envelope
      // (channelId + structural JSON), so we never exceed the budget even
      // when a stream is the first of its channel.
      final cost =
          _codec.encodedStreamDigestSize(item.digest) +
          item.channel.value.length +
          _channelEnvelopeOverheadBytes;

      if (base + cost > _maxMessageBytes) {
        oversized.add(
          OversizedDigest(
            channel: item.channel,
            streamId: item.digest.streamId,
            cost: cost,
          ),
        );
        consumed = i + 1;
        continue;
      }

      if (size + cost > _maxMessageBytes) break; // window full

      size += cost;
      selected.putIfAbsent(item.channel, () => []).add(item.digest);
      consumed = i + 1;
    }

    final digests = selected.entries
        .map((e) => ChannelDigest(channelId: e.key, streams: e.value))
        .toList();
    return (digests, oversized, consumed);
  }
}
