import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/chat_controller.dart';
import '../view_models/view_models.dart';
import '../widgets/animated_empty_state.dart';
import '../widgets/message_bubble.dart';
import '../widgets/message_input_bar.dart';
import '../widgets/new_messages_pill.dart';
import '../widgets/node_avatar.dart';
import '../widgets/typing_indicator.dart';
import 'qr_code_dialog.dart';

class ChatScreen extends StatefulWidget {
  final ChatController controller;

  const ChatScreen({super.key, required this.controller});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scrollController = ScrollController();
  int _lastSeenMessageCount = 0;
  int _newMessagesCount = 0;
  bool _isNearBottom = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    widget.controller.addListener(_onMessagesChanged);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    widget.controller.removeListener(_onMessagesChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    final isNearBottom = position.pixels >= position.maxScrollExtent - 100;

    if (isNearBottom != _isNearBottom) {
      setState(() {
        _isNearBottom = isNearBottom;
        if (isNearBottom) {
          _newMessagesCount = 0;
          _lastSeenMessageCount = widget.controller.currentMessages.length;
        }
      });
    }
  }

  void _onMessagesChanged() {
    final currentCount = widget.controller.currentMessages.length;
    if (currentCount > _lastSeenMessageCount && !_isNearBottom) {
      setState(() {
        _newMessagesCount = currentCount - _lastSeenMessageCount;
      });
    } else if (_isNearBottom) {
      _lastSeenMessageCount = currentCount;
      if (_newMessagesCount > 0) {
        setState(() {
          _newMessagesCount = 0;
        });
      }
    }
  }

  void _onSendMessage(String text) {
    widget.controller.sendMessage(text);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _copyChannelId() {
    final channel = widget.controller.currentChannel;
    if (channel != null) {
      Clipboard.setData(ClipboardData(text: channel.id.value));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Channel ID copied to clipboard')),
      );
    }
  }

  void _showQrCode() {
    final channel = widget.controller.currentChannel;
    if (channel != null) {
      QrCodeDialog.show(
        context,
        channelId: channel.id.value,
        channelName: channel.name,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final channel = widget.controller.currentChannel;
        if (channel == null) {
          return const Scaffold(
            body: Center(child: Text('No channel selected')),
          );
        }

        final theme = Theme.of(context);

        return Scaffold(
          appBar: AppBar(
            leadingWidth: 96,
            leading: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    widget.controller.clearCurrentChannel();
                    Navigator.of(context).pop();
                  },
                  tooltip: 'Back',
                ),
                Hero(
                  tag: 'channel_icon_${channel.id.value}',
                  child: NodeAvatar(
                    identifier: channel.id.value,
                    displayText: channel.name,
                    radius: 16,
                  ),
                ),
              ],
            ),
            titleSpacing: 8,
            title: Hero(
              tag: 'channel_name_${channel.id.value}',
              child: Material(
                color: Colors.transparent,
                child: Text(channel.name, style: theme.textTheme.titleLarge),
              ),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.qr_code),
                onPressed: _showQrCode,
                tooltip: 'Share channel',
              ),
              IconButton(
                icon: const Icon(Icons.info_outline),
                onPressed: _copyChannelId,
                tooltip: 'Copy channel ID',
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    _buildMessageList(),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 8,
                      child: Center(
                        child: NewMessagesPill(
                          count: _newMessagesCount,
                          visible: _newMessagesCount > 0,
                          onTap: _scrollToBottom,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              TypingIndicator(
                typingUserNames: widget.controller.typingUsers
                    .map(
                      (nodeId) => widget.controller.getTypingUserName(nodeId),
                    )
                    .whereType<String>()
                    .toList(),
              ),
              MessageInputBar(
                onSend: _onSendMessage,
                onTypingChanged: widget.controller.setTyping,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMessageList() {
    final messages = widget.controller.currentMessages;

    if (messages.isEmpty) {
      return const AnimatedEmptyState(
        icon: Icons.chat_bubble_outline,
        iconSize: 48,
        title: 'No messages yet',
        subtitle: 'Be the first to say something!',
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final groupPosition = calculateGroupPosition(messages, index);
        return MessageBubble(
          message: message,
          groupPosition: groupPosition,
          onRetry: message.deliveryStatus == MessageDeliveryStatus.failed
              ? () => widget.controller.retryMessage(message.id)
              : null,
        );
      },
    );
  }
}
