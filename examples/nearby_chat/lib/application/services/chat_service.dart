import 'dart:async';

import 'package:gossip/gossip.dart';
import 'package:uuid/uuid.dart';

import '../../domain/entities/entities.dart';
import '../../infrastructure/codecs/codecs.dart';

/// Stream IDs used within each channel.
abstract class StreamIds {
  static final messages = StreamId('messages');
  static final presence = StreamId('presence');
  static final metadata = StreamId('metadata');
}

/// Callback for reporting service errors.
typedef ServiceErrorCallback = void Function(String operation, Object error);

/// Service for managing chat channels and messages.
///
/// This is an application layer service that orchestrates domain operations
/// and delegates serialization to infrastructure codecs.
class ChatService {
  final Coordinator _coordinator;
  final NodeId _localNodeId;
  final String _displayName;
  final ServiceErrorCallback? _onError;
  final _uuid = const Uuid();

  // Infrastructure codecs
  final _messageCodec = const ChatMessageCodec();
  final _metadataCodec = const ChannelMetadataCodec();
  final _typingCodec = const TypingEventCodec();

  ChatService({
    required Coordinator coordinator,
    required NodeId localNodeId,
    required String displayName,
    ServiceErrorCallback? onError,
  }) : _coordinator = coordinator,
       _localNodeId = localNodeId,
       _displayName = displayName,
       _onError = onError;

  /// Creates a new channel with the given name.
  Future<ChannelId> createChannel(String name) async {
    final channelId = ChannelId(_uuid.v4());

    try {
      final channel = await _coordinator.createChannel(channelId);

      // Create streams
      await channel.getOrCreateStream(
        StreamIds.messages,
        retention: const KeepAllRetention(),
      );
      await channel.getOrCreateStream(
        StreamIds.presence,
        retention: const KeepAllRetention(),
      );
      await channel.getOrCreateStream(
        StreamIds.metadata,
        retention: const KeepAllRetention(),
      );

      // Store channel metadata
      final metadata = ChannelMetadata(name: name, createdAt: DateTime.now());
      final metadataStream = channel.getStream(StreamIds.metadata);
      await metadataStream.append(_metadataCodec.encode(metadata));

      return channelId;
    } catch (e) {
      _onError?.call('createChannel', e);
      rethrow;
    }
  }

  /// Joins an existing channel by ID.
  Future<void> joinChannel(ChannelId channelId) async {
    try {
      final channel = await _coordinator.createChannel(channelId);

      // Ensure streams exist
      await channel.getOrCreateStream(
        StreamIds.messages,
        retention: const KeepAllRetention(),
      );
      await channel.getOrCreateStream(
        StreamIds.presence,
        retention: const KeepAllRetention(),
      );
      await channel.getOrCreateStream(
        StreamIds.metadata,
        retention: const KeepAllRetention(),
      );
    } catch (e) {
      _onError?.call('joinChannel', e);
      rethrow;
    }
  }

  /// Leaves a channel (removes it locally).
  Future<void> leaveChannel(ChannelId channelId) async {
    try {
      await _coordinator.removeChannel(channelId);
    } catch (e) {
      _onError?.call('leaveChannel', e);
      rethrow;
    }
  }

  /// Gets all channel IDs.
  List<ChannelId> get channelIds => _coordinator.channelIds;

  /// Gets the metadata for a channel.
  ///
  /// Returns `null` if the channel doesn't exist or has no metadata.
  Future<ChannelMetadata?> getChannelMetadata(ChannelId channelId) async {
    try {
      final channel = _coordinator.getChannel(channelId);
      if (channel == null) {
        _onError?.call('getChannelMetadata', 'Channel not found: $channelId');
        return null;
      }

      final metadataStream = channel.getStream(StreamIds.metadata);
      final entries = await metadataStream.getAll();

      // Return the most recent metadata
      for (final entry in entries.reversed) {
        final metadata = _metadataCodec.decode(entry.payload);
        if (metadata != null) return metadata;
      }
      return null;
    } catch (e) {
      _onError?.call('getChannelMetadata', e);
      return null;
    }
  }

  /// Sends a message to a channel.
  Future<void> sendMessage(ChannelId channelId, String text) async {
    try {
      final channel = _coordinator.getChannel(channelId);
      if (channel == null) {
        _onError?.call('sendMessage', 'Channel not found: $channelId');
        return;
      }

      final message = ChatMessage(
        id: _uuid.v4(),
        text: text,
        senderName: _displayName,
        senderNode: _localNodeId,
        sentAt: DateTime.now(),
      );

      final messageStream = channel.getStream(StreamIds.messages);
      await messageStream.append(_messageCodec.encode(message));

      // Clear typing indicator when sending
      await setTyping(channelId, false);
    } catch (e) {
      _onError?.call('sendMessage', e);
      rethrow;
    }
  }

  /// Gets all messages for a channel.
  Future<List<ChatMessage>> getMessages(ChannelId channelId) async {
    try {
      final channel = _coordinator.getChannel(channelId);
      if (channel == null) {
        _onError?.call('getMessages', 'Channel not found: $channelId');
        return [];
      }

      final messageStream = channel.getStream(StreamIds.messages);
      final entries = await messageStream.getAll();

      final messages = <ChatMessage>[];
      for (final entry in entries) {
        final message = _messageCodec.decode(entry.payload);
        if (message != null) {
          messages.add(message);
        }
      }
      return messages;
    } catch (e) {
      _onError?.call('getMessages', e);
      return [];
    }
  }

  /// Sets the typing state for the local user in a channel.
  Future<void> setTyping(ChannelId channelId, bool isTyping) async {
    try {
      final channel = _coordinator.getChannel(channelId);
      if (channel == null) return;

      final event = TypingEvent(
        senderNode: _localNodeId,
        senderName: _displayName,
        isTyping: isTyping,
        timestamp: DateTime.now(),
      );

      final presenceStream = channel.getStream(StreamIds.presence);
      await presenceStream.append(_typingCodec.encode(event));
    } catch (e) {
      _onError?.call('setTyping', e);
      // Don't rethrow - typing is non-critical
    }
  }

  /// Gets the current typing users for a channel.
  Future<Map<NodeId, TypingEvent>> getTypingUsers(ChannelId channelId) async {
    try {
      final channel = _coordinator.getChannel(channelId);
      if (channel == null) return {};

      final presenceStream = channel.getStream(StreamIds.presence);
      final entries = await presenceStream.getAll();

      // Build map of latest typing state per user
      final typingState = <NodeId, TypingEvent>{};
      for (final entry in entries) {
        final event = _typingCodec.decode(entry.payload);
        if (event != null) {
          typingState[event.senderNode] = event;
        }
      }

      // Filter to only those currently typing (excluding self)
      final now = DateTime.now();
      const expirationDuration = Duration(seconds: 5);

      typingState.removeWhere((nodeId, event) {
        if (nodeId == _localNodeId) return true;
        if (!event.isTyping) return true;
        if (now.difference(event.timestamp) > expirationDuration) return true;
        return false;
      });

      return typingState;
    } catch (e) {
      _onError?.call('getTypingUsers', e);
      return {};
    }
  }

  /// The local node ID.
  NodeId get localNodeId => _localNodeId;
}
