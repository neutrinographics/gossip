import 'package:flutter/material.dart';

/// A floating pill that shows when there are new messages below the viewport.
///
/// Displays a count of new messages and scrolls to the bottom when tapped.
class NewMessagesPill extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  final bool visible;

  const NewMessagesPill({
    super.key,
    required this.count,
    required this.onTap,
    required this.visible,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: AnimatedSlide(
        offset: visible ? Offset.zero : const Offset(0, 1),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        child: IgnorePointer(
          ignoring: !visible,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: colorScheme.shadow.withValues(alpha: 0.15),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.arrow_downward,
                    size: 16,
                    color: colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$count new message${count == 1 ? '' : 's'}',
                    style: TextStyle(
                      color: colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
