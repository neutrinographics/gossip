import 'dart:math' as math;

import 'package:flutter/material.dart';

/// An animated status indicator with different animations based on state.
///
/// - Connected: Solid green dot with subtle pulse
/// - Discovering: Radar sweep animation
/// - Advertising: Breathing glow effect
/// - Disconnected: Static grey outline
class AnimatedStatusIndicator extends StatefulWidget {
  final StatusIndicatorState state;
  final double size;

  const AnimatedStatusIndicator({
    super.key,
    required this.state,
    this.size = 12,
  });

  @override
  State<AnimatedStatusIndicator> createState() =>
      _AnimatedStatusIndicatorState();
}

enum StatusIndicatorState { connected, discovering, advertising, disconnected }

class _AnimatedStatusIndicatorState extends State<AnimatedStatusIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _updateAnimation();
  }

  @override
  void didUpdateWidget(AnimatedStatusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _updateAnimation();
    }
  }

  void _updateAnimation() {
    if (widget.state == StatusIndicatorState.disconnected) {
      _controller.stop();
      _controller.reset();
    } else {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            painter: _StatusIndicatorPainter(
              state: widget.state,
              progress: _controller.value,
            ),
          );
        },
      ),
    );
  }
}

class _StatusIndicatorPainter extends CustomPainter {
  final StatusIndicatorState state;
  final double progress;

  _StatusIndicatorPainter({required this.state, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    switch (state) {
      case StatusIndicatorState.connected:
        _paintConnected(canvas, center, radius);
      case StatusIndicatorState.discovering:
        _paintDiscovering(canvas, center, radius);
      case StatusIndicatorState.advertising:
        _paintAdvertising(canvas, center, radius);
      case StatusIndicatorState.disconnected:
        _paintDisconnected(canvas, center, radius);
    }
  }

  void _paintConnected(Canvas canvas, Offset center, double radius) {
    // Subtle pulse effect
    final pulseScale = 1.0 + 0.15 * math.sin(progress * 2 * math.pi);
    final pulseRadius = radius * pulseScale;

    // Outer glow
    final glowPaint = Paint()
      ..color = Colors.green.withValues(alpha: 0.3 * (1 - progress))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, pulseRadius * 1.5, glowPaint);

    // Main dot
    final paint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius * 0.8, paint);
  }

  void _paintDiscovering(Canvas canvas, Offset center, double radius) {
    // Base dot
    final basePaint = Paint()
      ..color = Colors.orange.withValues(alpha: 0.3)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius * 0.5, basePaint);

    // Expanding rings
    for (var i = 0; i < 2; i++) {
      final ringProgress = (progress + i * 0.5) % 1.0;
      final ringRadius = radius * 0.3 + radius * 0.9 * ringProgress;
      final ringOpacity = 1.0 - ringProgress;

      final ringPaint = Paint()
        ..color = Colors.orange.withValues(alpha: ringOpacity * 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * (1 - ringProgress * 0.5);

      canvas.drawCircle(center, ringRadius, ringPaint);
    }

    // Center dot
    final centerPaint = Paint()
      ..color = Colors.orange
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius * 0.35, centerPaint);
  }

  void _paintAdvertising(Canvas canvas, Offset center, double radius) {
    // Breathing glow effect
    final breathe = 0.5 + 0.5 * math.sin(progress * 2 * math.pi);

    // Outer glow
    final glowRadius = radius * (1.0 + 0.4 * breathe);
    final glowPaint = Paint()
      ..color = Colors.blue.withValues(alpha: 0.2 + 0.2 * breathe)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, glowRadius, glowPaint);

    // Inner glow
    final innerGlowPaint = Paint()
      ..color = Colors.blue.withValues(alpha: 0.3 + 0.2 * breathe)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius * 0.9, innerGlowPaint);

    // Core
    final corePaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius * 0.6, corePaint);
  }

  void _paintDisconnected(Canvas canvas, Offset center, double radius) {
    final paint = Paint()
      ..color = Colors.grey
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, radius * 0.7, paint);
  }

  @override
  bool shouldRepaint(_StatusIndicatorPainter oldDelegate) {
    return oldDelegate.state != state || oldDelegate.progress != progress;
  }
}
