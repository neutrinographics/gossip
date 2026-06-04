import 'package:flutter/material.dart';

import '../view_models/ble_health.dart';

/// Three-bar BLE signal strength indicator driven by [BleHealth].
///
/// Distinct from `SignalStrengthIndicator` (which surfaces gossip
/// protocol health derived from SWIM probe failures). Both are
/// rendered side-by-side per peer row.
///
/// When the scanner isn't running ([scanningActive] = false), the
/// widget greys out regardless of [health]'s value — RSSI without a
/// recent scan emission is stale.
class BleSignalIndicator extends StatelessWidget {
  final BleHealth health;
  final bool scanningActive;
  final double size;

  const BleSignalIndicator({
    super.key,
    required this.health,
    this.scanningActive = true,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final effectiveHealth = scanningActive ? health : BleHealth.unknown;

    final (filledBars, color) = switch (effectiveHealth) {
      BleHealth.excellent => (3, colorScheme.primary),
      BleHealth.good => (3, colorScheme.primary),
      BleHealth.fair => (2, colorScheme.secondary),
      BleHealth.poor => (1, colorScheme.error),
      BleHealth.unknown => (0, colorScheme.outline),
    };

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _BarsPainter(
          filledBars: filledBars,
          color: color,
          emptyColor: colorScheme.outlineVariant,
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final int filledBars;
  final Color color;
  final Color emptyColor;

  _BarsPainter({
    required this.filledBars,
    required this.color,
    required this.emptyColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final barWidth = size.width * 0.22;
    final spacing = size.width * 0.06;
    final heights = [size.height * 0.4, size.height * 0.7, size.height];

    for (var i = 0; i < 3; i++) {
      final paint = Paint()
        ..color = i < filledBars ? color : emptyColor
        ..style = PaintingStyle.fill;
      final x = (size.width - (3 * barWidth + 2 * spacing)) / 2 +
          i * (barWidth + spacing);
      final y = size.height - heights[i];
      canvas.drawRect(Rect.fromLTWH(x, y, barWidth, heights[i]), paint);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.filledBars != filledBars ||
      old.color != color ||
      old.emptyColor != emptyColor;
}
