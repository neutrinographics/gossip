import 'package:flutter/material.dart';

import '../view_models/message_state.dart';

/// Position of a message within a group of consecutive messages from the same sender.
enum MessageGroupPosition {
  /// Single message, not grouped.
  standalone,

  /// First message in a group.
  first,

  /// Middle message in a group.
  middle,

  /// Last message in a group.
  last,
}

/// A chat message bubble with grouping support and delivery status.
///
/// Messages from the same sender are visually grouped by adjusting border radius
/// and hiding redundant sender names.
class MessageBubble extends StatelessWidget {
  final MessageState message;
  final MessageGroupPosition groupPosition;

  /// Called when the user taps retry on a failed message.
  final VoidCallback? onRetry;

  const MessageBubble({
    super.key,
    required this.message,
    this.groupPosition = MessageGroupPosition.standalone,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isLocal = message.isLocal;

    // Determine border radius based on group position
    final borderRadius = _getBorderRadius(isLocal);

    // Determine vertical spacing based on group position
    final topPadding =
        groupPosition == MessageGroupPosition.first ||
            groupPosition == MessageGroupPosition.standalone
        ? 8.0
        : 2.0;
    final bottomPadding =
        groupPosition == MessageGroupPosition.last ||
            groupPosition == MessageGroupPosition.standalone
        ? 8.0
        : 2.0;

    // Show sender name only for first message in group (remote only)
    final showSenderName =
        !isLocal &&
        (groupPosition == MessageGroupPosition.first ||
            groupPosition == MessageGroupPosition.standalone);

    return Padding(
      padding: EdgeInsets.only(
        top: topPadding,
        bottom: bottomPadding,
        left: 16,
        right: 16,
      ),
      child: Row(
        mainAxisAlignment: isLocal
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isLocal) const SizedBox(width: 40),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isLocal
                    ? colorScheme.primary
                    : colorScheme.surfaceContainerHighest,
                borderRadius: borderRadius,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: isLocal
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  if (showSenderName)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        message.senderName,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                  Text(
                    message.text,
                    style: TextStyle(
                      color: isLocal
                          ? colorScheme.onPrimary
                          : colorScheme.onSurface,
                      fontSize: 15,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatTime(message.sentAt),
                        style: TextStyle(
                          fontSize: 11,
                          color: isLocal
                              ? colorScheme.onPrimary.withValues(alpha: 0.7)
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (isLocal) ...[
                        const SizedBox(width: 4),
                        _buildDeliveryIndicator(colorScheme),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (isLocal) const SizedBox(width: 40),
        ],
      ),
    );
  }

  BorderRadius _getBorderRadius(bool isLocal) {
    const largeRadius = Radius.circular(18);
    const smallRadius = Radius.circular(6);

    if (isLocal) {
      switch (groupPosition) {
        case MessageGroupPosition.standalone:
          return const BorderRadius.all(largeRadius);
        case MessageGroupPosition.first:
          return const BorderRadius.only(
            topLeft: largeRadius,
            topRight: largeRadius,
            bottomLeft: largeRadius,
            bottomRight: smallRadius,
          );
        case MessageGroupPosition.middle:
          return const BorderRadius.only(
            topLeft: largeRadius,
            topRight: smallRadius,
            bottomLeft: largeRadius,
            bottomRight: smallRadius,
          );
        case MessageGroupPosition.last:
          return const BorderRadius.only(
            topLeft: largeRadius,
            topRight: smallRadius,
            bottomLeft: largeRadius,
            bottomRight: largeRadius,
          );
      }
    } else {
      switch (groupPosition) {
        case MessageGroupPosition.standalone:
          return const BorderRadius.all(largeRadius);
        case MessageGroupPosition.first:
          return const BorderRadius.only(
            topLeft: largeRadius,
            topRight: largeRadius,
            bottomLeft: smallRadius,
            bottomRight: largeRadius,
          );
        case MessageGroupPosition.middle:
          return const BorderRadius.only(
            topLeft: smallRadius,
            topRight: largeRadius,
            bottomLeft: smallRadius,
            bottomRight: largeRadius,
          );
        case MessageGroupPosition.last:
          return const BorderRadius.only(
            topLeft: smallRadius,
            topRight: largeRadius,
            bottomLeft: largeRadius,
            bottomRight: largeRadius,
          );
      }
    }
  }

  Widget _buildDeliveryIndicator(ColorScheme colorScheme) {
    switch (message.deliveryStatus) {
      case MessageDeliveryStatus.sending:
        return SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: colorScheme.onPrimary.withValues(alpha: 0.7),
          ),
        );
      case MessageDeliveryStatus.sent:
        return Icon(
          Icons.check,
          size: 14,
          color: colorScheme.onPrimary.withValues(alpha: 0.7),
        );
      case MessageDeliveryStatus.failed:
        return GestureDetector(
          onTap: onRetry,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 14, color: colorScheme.error),
              if (onRetry != null) ...[
                const SizedBox(width: 4),
                Text(
                  'Retry',
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.error,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        );
    }
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

/// Calculates the group position for a message at the given index.
MessageGroupPosition calculateGroupPosition(
  List<MessageState> messages,
  int index,
) {
  if (messages.isEmpty) return MessageGroupPosition.standalone;

  final current = messages[index];
  final hasPrevious = index > 0;
  final hasNext = index < messages.length - 1;

  final sameSenderAsPrevious =
      hasPrevious && messages[index - 1].senderNode == current.senderNode;
  final sameSenderAsNext =
      hasNext && messages[index + 1].senderNode == current.senderNode;

  if (sameSenderAsPrevious && sameSenderAsNext) {
    return MessageGroupPosition.middle;
  } else if (sameSenderAsPrevious) {
    return MessageGroupPosition.last;
  } else if (sameSenderAsNext) {
    return MessageGroupPosition.first;
  } else {
    return MessageGroupPosition.standalone;
  }
}
