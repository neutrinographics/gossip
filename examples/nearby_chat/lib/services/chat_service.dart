import 'dart:async';

import 'package:gossip/gossip.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';

/// Stream IDs used within each channel.
abstract class StreamIds {
  static final messages = StreamId('messages');
  static final presence = StreamId('presence');
  static final metadata = StreamId('metadata');
}

/// Service for managing chat channels and messages.
class ChatService {
  final Coordinator _coordinator;
  final NodeId _localNodeId;
  final String _displayName;
  final _uuid = const Uuid();

  ChatService({
    required Coordinator coordinator,
    required NodeId localNodeId,
    required String displayName,
  }) : _coordinator = coordinator,
       _localNodeId = localNodeId,
       _displayName = displayName;

  /// Creates a new channel with the given name.
  Future<ChannelId> createChannel(String name) async {
    final channelId = ChannelId(_uuid.v4());
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
    await metadataStream.append(metadata.encode());

    return channelId;
  }

  /// Joins an existing channel by ID.
  Future<void> joinChannel(ChannelId channelId) async {
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
  }

  /// Leaves a channel (removes it locally).
  Future<void> leaveChannel(ChannelId channelId) async {
    await _coordinator.removeChannel(channelId);
  }

  /// Gets all channel IDs.
  List<ChannelId> get channelIds => _coordinator.channelIds;

  /// Gets the metadata for a channel.
  Future<ChannelMetadata?> getChannelMetadata(ChannelId channelId) async {
    final channel = _coordinator.getChannel(channelId);
    if (channel == null) return null;

    final metadataStream = channel.getStream(StreamIds.metadata);
    final entries = await metadataStream.getAll();

    // Return the most recent metadata
    for (final entry in entries.reversed) {
      final metadata = ChannelMetadata.decode(entry.payload);
      if (metadata != null) return metadata;
    }
    return null;
  }

  /// Sends a message to a channel.
  Future<void> sendMessage(ChannelId channelId, String text) async {
    final channel = _coordinator.getChannel(channelId);
    if (channel == null) return;

    final message = ChatMessage(
      id: _uuid.v4(),
      text: text,
      senderName: _displayName,
      senderNode: _localNodeId,
      sentAt: DateTime.now(),
    );

    final messageStream = channel.getStream(StreamIds.messages);
    await messageStream.append(message.encode());

    // Clear typing indicator when sending
    await setTyping(channelId, false);
  }

  /// Gets all messages for a channel.
  Future<List<ChatMessage>> getMessages(ChannelId channelId) async {
    final channel = _coordinator.getChannel(channelId);
    if (channel == null) return [];

    final messageStream = channel.getStream(StreamIds.messages);
    final entries = await messageStream.getAll();

    final messages = <ChatMessage>[];
    for (final entry in entries) {
      final message = ChatMessage.decode(entry.payload);
      if (message != null) {
        messages.add(message);
      }
    }
    return messages;
  }

  /// Sets the typing state for the local user in a channel.
  Future<void> setTyping(ChannelId channelId, bool isTyping) async {
    final channel = _coordinator.getChannel(channelId);
    if (channel == null) return;

    final event = TypingEvent(
      senderNode: _localNodeId,
      senderName: _displayName,
      isTyping: isTyping,
      timestamp: DateTime.now(),
    );

    final presenceStream = channel.getStream(StreamIds.presence);
    await presenceStream.append(event.encode());
  }

  /// Gets the current typing users for a channel.
  Future<Map<NodeId, TypingEvent>> getTypingUsers(ChannelId channelId) async {
    final channel = _coordinator.getChannel(channelId);
    if (channel == null) return {};

    final presenceStream = channel.getStream(StreamIds.presence);
    final entries = await presenceStream.getAll();

    // Build map of latest typing state per user
    final typingState = <NodeId, TypingEvent>{};
    for (final entry in entries) {
      final event = TypingEvent.decode(entry.payload);
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
  }

  /// The local node ID.
  NodeId get localNodeId => _localNodeId;
}
