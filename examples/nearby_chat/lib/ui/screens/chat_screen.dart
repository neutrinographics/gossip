import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/chat_controller.dart';
import '../../models/models.dart';

class ChatScreen extends StatefulWidget {
  final ChatController controller;

  const ChatScreen({super.key, required this.controller});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = _textController.text.isNotEmpty;
    widget.controller.setTyping(hasText);
  }

  void _sendMessage() {
    final text = _textController.text;
    if (text.trim().isEmpty) return;

    widget.controller.sendMessage(text);
    _textController.clear();
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

        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                widget.controller.clearCurrentChannel();
                Navigator.of(context).pop();
              },
            ),
            title: Text('# ${channel.name}'),
            actions: [
              IconButton(
                icon: const Icon(Icons.info_outline),
                onPressed: _copyChannelId,
                tooltip: 'Copy channel ID',
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(child: _buildMessageList()),
              _buildTypingIndicator(),
              _buildMessageInput(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMessageList() {
    final messages = widget.controller.currentMessages;

    if (messages.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey),
            SizedBox(height: 16),
            Text('No messages yet', style: TextStyle(color: Colors.grey)),
            SizedBox(height: 8),
            Text(
              'Be the first to say something!',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        return _MessageBubble(message: message);
      },
    );
  }

  Widget _buildTypingIndicator() {
    final typingText = widget.controller.getTypingIndicatorText();
    if (typingText.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      alignment: Alignment.centerLeft,
      child: Text(
        typingText,
        style: TextStyle(
          color: Colors.grey.shade600,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  Widget _buildMessageInput() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                decoration: const InputDecoration(
                  hintText: 'Type a message...',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _sendMessage,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final MessageState message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isLocal = message.isLocal;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: isLocal
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!isLocal) const SizedBox(width: 48),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isLocal
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: isLocal
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  if (!isLocal)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        message.senderName,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ),
                  Text(
                    message.text,
                    style: TextStyle(
                      color: isLocal ? Colors.white : Colors.black,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatTime(message.sentAt),
                    style: TextStyle(
                      fontSize: 10,
                      color: isLocal
                          ? Colors.white.withValues(alpha: 0.7)
                          : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isLocal) const SizedBox(width: 48),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
