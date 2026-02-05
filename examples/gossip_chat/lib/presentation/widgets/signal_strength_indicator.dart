import 'package:flutter/material.dart';

/// Displays signal strength as 1-3 vertical bars.
///
/// Similar to cellular/WiFi signal indicators on mobile devices.
/// The bars are colored based on strength:
/// - 3 bars: All bars filled (excellent connection)
/// - 2 bars: Two bars filled (good connection)
/// - 1 bar: One bar filled (poor connection)
class SignalStrengthIndicator extends StatelessWidget {
  /// Signal strength from 1-3.
  final int strength;

  /// Size of the indicator (height of tallest bar).
  final double size;

  /// Color for active (filled) bars. Defaults to theme's primary color.
  final Color? activeColor;

  /// Color for inactive (unfilled) bars. Defaults to theme's outline color.
  final Color? inactiveColor;

  const SignalStrengthIndicator({
    super.key,
    required this.strength,
    this.size = 16,
    this.activeColor,
    this.inactiveColor,
  }) : assert(strength >= 1 && strength <= 3);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final active = activeColor ?? _getActiveColor(colorScheme);
    final inactive = inactiveColor ?? colorScheme.outlineVariant;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _buildBar(1, active, inactive),
        SizedBox(width: size * 0.15),
        _buildBar(2, active, inactive),
        SizedBox(width: size * 0.15),
        _buildBar(3, active, inactive),
      ],
    );
  }

  /// Returns color based on signal strength.
  Color _getActiveColor(ColorScheme colorScheme) {
    switch (strength) {
      case 3:
        return colorScheme.primary;
      case 2:
        return colorScheme.tertiary;
      default:
        return colorScheme.error;
    }
  }

  Widget _buildBar(int barIndex, Color active, Color inactive) {
    final isActive = barIndex <= strength;
    // Bar heights: 40%, 70%, 100% of size
    final heightPercent = switch (barIndex) {
      1 => 0.4,
      2 => 0.7,
      _ => 1.0,
    };

    return Container(
      width: size * 0.22,
      height: size * heightPercent,
      decoration: BoxDecoration(
        color: isActive ? active : inactive,
        borderRadius: BorderRadius.circular(size * 0.1),
      ),
    );
  }
}
