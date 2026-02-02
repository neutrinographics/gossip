import 'package:flutter/material.dart';

/// An animated typing indicator showing bouncing dots.
///
/// Displays the names of users who are typing along with an animated
/// "..." that bounces to indicate activity.
class TypingIndicator extends StatefulWidget {
  /// The names of users currently typing.
  final List<String> typingUserNames;

  const TypingIndicator({super.key, required this.typingUserNames});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with TickerProviderStateMixin {
  late AnimationController _controller;
  late List<Animation<double>> _dotAnimations;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    // Stagger the dots with overlapping animations
    _dotAnimations = List.generate(3, (index) {
      final start = index * 0.2;
      final end = start + 0.4;
      return Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(
          parent: _controller,
          curve: Interval(start, end.clamp(0.0, 1.0), curve: Curves.easeInOut),
        ),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _buildTypingText() {
    final names = widget.typingUserNames;
    if (names.isEmpty) return '';
    if (names.length == 1) return '${names[0]} is typing';
    if (names.length == 2) return '${names[0]} and ${names[1]} are typing';
    return '${names.length} people are typing';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.typingUserNames.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _buildTypingText(),
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(width: 4),
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(3, (index) {
                  return Transform.translate(
                    offset: Offset(
                      0,
                      -4 * _bounceValue(_dotAnimations[index].value),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.7,
                          ),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                }),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Creates a bounce effect: up then down
  double _bounceValue(double t) {
    // Use sine curve for smooth bounce
    return (t < 0.5) ? t * 2 : (1 - t) * 2;
  }
}
