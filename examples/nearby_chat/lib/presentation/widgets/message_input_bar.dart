import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A message input bar widget with text field and animated send button.
///
/// Handles text input, typing state changes, and message submission.
/// Features an animated send button that scales up when text is entered.
class MessageInputBar extends StatefulWidget {
  /// Called when the user submits a message.
  final ValueChanged<String> onSend;

  /// Called when the typing state changes.
  final ValueChanged<bool> onTypingChanged;

  const MessageInputBar({
    super.key,
    required this.onSend,
    required this.onTypingChanged,
  });

  @override
  State<MessageInputBar> createState() => _MessageInputBarState();
}

class _MessageInputBarState extends State<MessageInputBar>
    with SingleTickerProviderStateMixin {
  final _textController = TextEditingController();
  late AnimationController _sendButtonController;
  late Animation<double> _sendButtonScale;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onTextChanged);

    _sendButtonController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );

    _sendButtonScale = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _sendButtonController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _sendButtonController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = _textController.text.isNotEmpty;

    if (hasText != _hasText) {
      setState(() {
        _hasText = hasText;
      });

      if (hasText) {
        _sendButtonController.forward();
      } else {
        _sendButtonController.reverse();
      }
    }

    widget.onTypingChanged(hasText);
  }

  void _sendMessage() {
    final text = _textController.text;
    if (text.trim().isEmpty) return;

    HapticFeedback.lightImpact();
    widget.onSend(text);
    _textController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: _hasText
                      ? colorScheme.primaryContainer.withValues(alpha: 0.3)
                      : colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: _textController,
                  decoration: InputDecoration(
                    hintText: 'Type a message...',
                    hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            AnimatedBuilder(
              animation: _sendButtonScale,
              builder: (context, child) {
                return Transform.scale(
                  scale: _sendButtonScale.value,
                  child: child,
                );
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: _hasText
                      ? colorScheme.primary
                      : colorScheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  onPressed: _hasText ? _sendMessage : null,
                  icon: Icon(
                    Icons.send,
                    color: _hasText
                        ? colorScheme.onPrimary
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
