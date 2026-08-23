import 'package:gossip/src/shared/shared.dart';
import 'package:gossip/src/sync/sync.dart';
import 'package:gossip/src/coordinator/event_stream.dart';

/// Public API for channel-level operations.
///
/// A [Channel] is a logical grouping of event streams that can be shared
/// between peers. Channels provide:
/// - **Membership management**: Control which peers participate
/// - **Stream access**: Create and access event streams within the channel
///
/// ## Creating and Accessing Channels
///
/// Channels are created via Coordinator.createChannel:
///
/// ```dart
/// final channel = await coordinator.createChannel(ChannelId('my-channel'));
/// ```
///
/// Access existing channels with Coordinator.getChannel:
///
/// ```dart
/// final channel = coordinator.getChannel(ChannelId('my-channel'));
/// if (channel != null) {
///   // Channel exists
/// }
/// ```
///
/// ## Working with Streams
///
/// Each channel can contain multiple event streams:
///
/// ```dart
/// // Create or get a stream
/// final messages = await channel.getOrCreateStream(StreamId('messages'));
/// final metadata = await channel.getOrCreateStream(StreamId('metadata'));
///
/// // List all streams
/// final streamIds = await channel.streamIds;
/// ```
///
/// ## Membership
///
/// Membership controls which peers are part of the channel. Note that
/// membership is **local metadata only** - it does not gate synchronization
/// at the protocol level (see ADR-007).
///
/// ```dart
/// // Add a peer as member
/// await channel.addMember(NodeId('peer-1'));
///
/// // Check members
/// final members = await channel.members;
/// print('Members: $members');
///
/// // Remove a member
/// await channel.removeMember(NodeId('peer-1'));
/// ```
///
/// ## Retention Policies
///
/// Streams can have retention policies to limit entry growth:
///
/// ```dart
/// final stream = await channel.getOrCreateStream(
///   StreamId('logs'),
///   retention: KeepAllRetention(), // Default: keep everything
/// );
/// ```
///
/// See also:
/// - [EventStream] for entry operations
/// - Coordinator for channel lifecycle management
/// - [RetentionPolicy] for available policies
class Channel {
  /// The channel identifier.
  final ChannelId id;

  /// The channel service for persistence operations.
  final ChannelService channelService;

  /// Creates a channel.
  const Channel({required this.id, required this.channelService});

  /// Returns the set of member node IDs in this channel.
  ///
  /// Membership is local metadata (see ADR-007): it names who this node
  /// considers part of the channel, but it is never encoded in any wire
  /// message and the protocol does not gate synchronization on it.
  /// Enforcement is an application concern.
  Future<Set<NodeId>> get members async {
    return await channelService.getMembers(id);
  }

  /// Adds a member to the channel's local metadata — this records intent
  /// for the app's own logic; it grants nothing at the protocol level
  /// (see ADR-007).
  Future<void> addMember(NodeId memberId) async {
    await channelService.addMember(id, memberId);
  }

  /// Removes a member from the channel's local metadata.
  ///
  /// This does NOT stop the peer from replicating the channel's entries:
  /// any node still holding the channel keeps receiving and serving its
  /// data (see ADR-007). Do not use this as access revocation — key
  /// rotation or app-level encryption is the tool for that.
  Future<void> removeMember(NodeId memberId) async {
    await channelService.removeMember(id, memberId);
  }

  /// Returns the list of stream IDs in this channel.
  Future<List<StreamId>> get streamIds async {
    return await channelService.getStreamIds(id);
  }

  /// Creates a stream if it doesn't exist, or returns the facade for an existing stream.
  ///
  /// The retention policy is only used when creating a new stream.
  ///
  /// Used when: Application needs access to a stream for reading/writing.
  Future<EventStream> getOrCreateStream(
    StreamId streamId, {
    RetentionPolicy? retention,
  }) async {
    final exists = await channelService.hasStream(id, streamId);
    if (!exists) {
      await channelService.createStream(
        id,
        streamId,
        retention ?? const KeepAllRetention(),
      );
    }
    return EventStream(
      id: streamId,
      channelId: id,
      channelService: channelService,
    );
  }

  /// Returns the facade for a stream.
  ///
  /// Always returns a facade even if the stream doesn't exist yet.
  /// Operations on the facade will fail if the stream doesn't exist.
  /// Use [getOrCreateStream] if you want to create the stream automatically.
  EventStream getStream(StreamId streamId) {
    // We always return a facade. Operations will fail if stream doesn't exist.
    // For a sync check, use getStreamIds() first.
    return EventStream(
      id: streamId,
      channelId: id,
      channelService: channelService,
    );
  }
}
