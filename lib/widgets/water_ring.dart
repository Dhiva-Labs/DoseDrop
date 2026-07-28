import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The ring: 180px, 12px stroke, rounded caps; track = outline, fill = water
/// accent; center shows today's total over the goal. Animates on change.
///
/// Reused smaller (with [compact]) for the Home screen's water card.
class WaterRing extends StatelessWidget {
  const WaterRing({
    super.key,
    required this.currentMl,
    required this.goalMl,
    this.size = 180,
    this.strokeWidth = 12,
    this.compact = false,
  });

  final int currentMl;
  final int goalMl;
  final double size;
  final double strokeWidth;

  /// Smaller center number and no "of X ml goal" second line — for the
  /// Home screen's compact water card.
  final bool compact;

  double get _progress =>
      goalMl <= 0 ? 0.0 : (currentMl / goalMl).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final textTheme = Theme.of(context).textTheme;
    final numberStyle = (compact ? textTheme.titleMedium : textTheme.headlineMedium)
        ?.copyWith(fontWeight: FontWeight.w800, fontFeatures: DD.tabular);
    final captionStyle = textTheme.bodySmall?.copyWith(color: t.ink3);

    return Semantics(
      label: '$currentMl of $goalMl milliliters of water today',
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: _progress),
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) => CustomPaint(
            painter: _WaterRingPainter(
              progress: value,
              trackColor: t.outline,
              fillColor: t.waterAccent,
              strokeWidth: strokeWidth,
            ),
            child: child,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('$currentMl', style: numberStyle),
                if (!compact) ...<Widget>[
                  const SizedBox(height: 2),
                  Text('of $goalMl ml goal', style: captionStyle),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WaterRingPainter extends CustomPainter {
  _WaterRingPainter({
    required this.progress,
    required this.trackColor,
    required this.fillColor,
    required this.strokeWidth,
  });

  final double progress;
  final Color trackColor;
  final Color fillColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;

    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, track);

    if (progress > 0) {
      final fill = Paint()
        ..color = fillColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;
      const start = -math.pi / 2;
      final sweep = 2 * math.pi * progress;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep,
        false,
        fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaterRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.fillColor != fillColor ||
      oldDelegate.strokeWidth != strokeWidth;
}
