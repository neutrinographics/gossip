import 'package:flutter/material.dart';

/// A deterministic avatar generated from a node ID or string identifier.
///
/// Creates a unique gradient avatar based on the hash of the identifier,
/// similar to GitHub's identicons. Each unique ID produces a consistent
/// color combination.
class NodeAvatar extends StatelessWidget {
  /// The identifier to generate the avatar from.
  final String identifier;

  /// Optional display text (usually first letter of name).
  final String? displayText;

  /// The radius of the avatar.
  final double radius;

  const NodeAvatar({
    super.key,
    required this.identifier,
    this.displayText,
    this.radius = 20,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _generateGradientColors(identifier);

    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        boxShadow: [
          BoxShadow(
            color: colors[0].withValues(alpha: 0.3),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: displayText != null
          ? Center(
              child: Text(
                displayText!.substring(0, 1).toUpperCase(),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: radius * 0.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : null,
    );
  }

  /// Generates two colors for a gradient based on the identifier hash.
  List<Color> _generateGradientColors(String id) {
    final hash = id.hashCode;

    // Use different parts of the hash for each color
    final hue1 = (hash & 0xFF) / 255 * 360;
    final hue2 = ((hash >> 8) & 0xFF) / 255 * 360;

    // Create vibrant, saturated colors
    final color1 = HSLColor.fromAHSL(1.0, hue1, 0.7, 0.5).toColor();
    final color2 = HSLColor.fromAHSL(1.0, hue2, 0.65, 0.45).toColor();

    return [color1, color2];
  }
}

/// A collection of predefined avatar color palettes for variety.
class AvatarPalettes {
  AvatarPalettes._();

  static const List<List<Color>> palettes = [
    [Color(0xFF6366F1), Color(0xFF8B5CF6)], // Indigo to Violet
    [Color(0xFF10B981), Color(0xFF059669)], // Emerald
    [Color(0xFFF59E0B), Color(0xFFD97706)], // Amber
    [Color(0xFFEF4444), Color(0xFFDC2626)], // Red
    [Color(0xFF3B82F6), Color(0xFF2563EB)], // Blue
    [Color(0xFFEC4899), Color(0xFFDB2777)], // Pink
    [Color(0xFF14B8A6), Color(0xFF0D9488)], // Teal
    [Color(0xFF8B5CF6), Color(0xFF7C3AED)], // Purple
  ];

  /// Gets a palette based on an identifier hash.
  static List<Color> forIdentifier(String id) {
    final index = id.hashCode.abs() % palettes.length;
    return palettes[index];
  }
}
