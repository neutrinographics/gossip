import 'package:gossip/gossip.dart';

/// UI state for a chat channel.
class ChannelState {
  final ChannelId id;
  final String name;
  final int unreadCount;
  final String? lastMessage;
  final DateTime? lastMessageAt;

  const ChannelState({
    required this.id,
    required this.name,
    this.unreadCount = 0,
    this.lastMessage,
    this.lastMessageAt,
  });

  ChannelState copyWith({
    String? name,
    int? unreadCount,
    String? lastMessage,
    DateTime? lastMessageAt,
  }) => ChannelState(
    id: id,
    name: name ?? this.name,
    unreadCount: unreadCount ?? this.unreadCount,
    lastMessage: lastMessage ?? this.lastMessage,
    lastMessageAt: lastMessageAt ?? this.lastMessageAt,
  );
}
