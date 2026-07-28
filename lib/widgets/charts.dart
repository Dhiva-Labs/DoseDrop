/// Weekly bar charts for the History screen (DESIGN.md §Charts).
///
/// These rules came from a validated dataviz procedure and are implemented
/// exactly, not loosely: single-hue series, no dual axes, selective direct
/// labels (never every bar), grid is horizontal-only, status/absence is
/// never implied by a second color.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/schedule_engine.dart' show Adherence;
import '../theme/app_theme.dart';

/// One day's water total, as returned by `AppState.waterMlByDay`.
typedef WaterDay = ({DateTime day, int ml});

/// One day's adherence, as returned by `AppState.adherenceByDay`.
typedef AdherenceDay = ({DateTime day, Adherence adherence});

const List<String> _weekdayLetters = <String>['M', 'T', 'W', 'T', 'F', 'S', 'S'];
const List<String> _weekdayNames = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

int _indexForX(double dx, double width, int columns) =>
    (dx / (width / columns)).floor().clamp(0, columns - 1);

const double _chartHeight = 150;
const double _topLabelPad = 28;
const double _maxBarWidth = 24.0;
const double _minBarGap = 2.0;
const double _dayAxisHeight = 48;

// ---------------------------------------------------------------------------
// Shared chrome: card wrapper + tappable day-letter axis under both charts
// ---------------------------------------------------------------------------

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.chart, required this.axis});

  final Widget chart;
  final Widget axis;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(DD.rCard),
        border: Border.all(color: t.outline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(height: _chartHeight, child: chart),
          axis,
        ],
      ),
    );
  }
}

/// Day letters (DESIGN.md: "day letters under both charts; today's letter
/// emphasized"). Also the accessible, always-readable-as-text stand-in for
/// the canvas bars: each cell's semantic label includes that day's value, so
/// a screen reader gets full information without needing the tap bubble.
class _DayLetterAxis extends StatelessWidget {
  const _DayLetterAxis({
    required this.days,
    required this.today,
    required this.highlightIndex,
    required this.onTap,
    required this.semanticValues,
  });

  final List<DateTime> days;
  final DateTime today;
  final int? highlightIndex;
  final ValueChanged<int> onTap;

  /// Same length as [days] — the value spoken after the weekday name.
  final List<String> semanticValues;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        for (var i = 0; i < days.length; i++)
          Expanded(
            child: _DayLetterCell(
              label: _weekdayLetters[days[i].weekday - 1],
              semanticLabel:
                  '${_weekdayNames[days[i].weekday - 1]}, ${semanticValues[i]}',
              isToday: _sameDay(days[i], today),
              isHighlighted: highlightIndex == i,
              onTap: () => onTap(i),
            ),
          ),
      ],
    );
  }
}

class _DayLetterCell extends StatelessWidget {
  const _DayLetterCell({
    required this.label,
    required this.semanticLabel,
    required this.isToday,
    required this.isHighlighted,
    required this.onTap,
  });

  final String label;
  final String semanticLabel;
  final bool isToday;
  final bool isHighlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    return Semantics(
      label: semanticLabel,
      button: true,
      selected: isHighlighted,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: _dayAxisHeight,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: isHighlighted
                  ? BoxDecoration(
                      color: t.cardAlt,
                      borderRadius: BorderRadius.circular(999),
                    )
                  : null,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isToday ? FontWeight.w800 : FontWeight.w500,
                  color: isToday ? t.ink : t.ink3,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared painter helpers: text labels + tap "value bubble"
// ---------------------------------------------------------------------------

abstract class _BarChartPainter extends CustomPainter {
  TextPainter _layout(String text, Color color, double fontSize, FontWeight weight) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: weight,
          fontFeatures: DD.tabular,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  /// A plain value label, bottom-center anchored just above a bar. Text is
  /// always [color] (inkPrimary) — DESIGN.md: "text never wears the series
  /// color".
  void drawCenteredLabel(Canvas canvas, String text, Offset bottomCenter, Color color) {
    final tp = _layout(text, color, 11, FontWeight.w700);
    tp.paint(canvas, Offset(bottomCenter.dx - tp.width / 2, bottomCenter.dy - tp.height));
  }

  /// Right-aligned caption label (used for the water chart's "goal" tag).
  void drawRightLabel(Canvas canvas, String text, Offset bottomRight, Color color) {
    final tp = _layout(text, color, 10, FontWeight.w600);
    tp.paint(canvas, Offset(bottomRight.dx - tp.width, bottomRight.dy - tp.height));
  }

  /// The tapped-bar "mobile tooltip equivalent": a small pill above the bar.
  void drawBubble(
    Canvas canvas,
    String text,
    Offset bottomCenter, {
    required Color bg,
    required Color fg,
  }) {
    final tp = _layout(text, fg, 11, FontWeight.w700);
    final rect = Rect.fromCenter(
      center: Offset(bottomCenter.dx, bottomCenter.dy - tp.height / 2 - 4),
      width: tp.width + 14,
      height: tp.height + 8,
    );
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(8)), Paint()..color = bg);
    tp.paint(canvas, Offset(rect.center.dx - tp.width / 2, rect.center.dy - tp.height / 2));
  }

  void drawHorizontalGrid(Canvas canvas, Size size, double top, double barAreaHeight, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (final f in const <double>[0.25, 0.5, 0.75, 1.0]) {
      final y = top + barAreaHeight * (1 - f);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  void drawDashedLine(Canvas canvas, double width, double y, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dash = 4.0;
    const gap = 3.0;
    var x = 0.0;
    while (x < width) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + dash, width), y), paint);
      x += dash + gap;
    }
  }
}

// ---------------------------------------------------------------------------
// Weekly water — DESIGN.md §Charts "Weekly water"
// ---------------------------------------------------------------------------

/// Vertical bars, single hue [DD.water] in both modes, ≤24px wide with
/// ≥2px gaps, 4px rounded top corners only, a dashed goal line, horizontal
/// hairline grid only, and value labels on today's bar and the max bar only.
class WaterWeekChart extends StatefulWidget {
  const WaterWeekChart({
    super.key,
    required this.days,
    required this.goalMl,
    required this.today,
    required this.onDayTap,
  });

  /// Exactly 7 entries, Monday first (as returned by `waterMlByDay`).
  final List<WaterDay> days;
  final int goalMl;
  final DateTime today;
  final ValueChanged<DateTime> onDayTap;

  @override
  State<WaterWeekChart> createState() => _WaterWeekChartState();
}

class _WaterWeekChartState extends State<WaterWeekChart> {
  int? _tapped;

  void _select(int index) {
    setState(() => _tapped = index);
    widget.onDayTap(widget.days[index].day);
  }

  @override
  void didUpdateWidget(covariant WaterWeekChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new week paged in: last week's tapped column means nothing here.
    if (oldWidget.days.first.day != widget.days.first.day) _tapped = null;
  }

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final values = <int>[for (final d in widget.days) d.ml];
    final maxValue = values.fold<int>(0, math.max);
    final scaleMax = math.max(maxValue, widget.goalMl) * 1.2;
    final safeScaleMax = scaleMax <= 0 ? 1.0 : scaleMax.toDouble();

    final todayIndex = widget.days.indexWhere((d) => _sameDay(d.day, widget.today));
    final maxIndex = maxValue <= 0 ? -1 : values.indexOf(maxValue);
    final labelIndices = <int>{
      if (todayIndex >= 0) todayIndex,
      if (maxIndex >= 0) maxIndex,
    };

    return _ChartCard(
      chart: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) =>
                _select(_indexForX(details.localPosition.dx, constraints.maxWidth, values.length)),
            child: CustomPaint(
              size: Size(constraints.maxWidth, _chartHeight),
              painter: _WaterBarsPainter(
                values: values,
                scaleMax: safeScaleMax,
                goalMl: widget.goalMl,
                highlightIndex: _tapped,
                labelIndices: labelIndices,
                barColor: DD.water,
                gridColor: t.outline,
                mutedColor: t.ink3,
                labelColor: t.ink,
                bubbleColor: t.ink,
                onBubbleColor: t.bg,
              ),
            ),
          ),
        ),
      ),
      axis: _DayLetterAxis(
        days: <DateTime>[for (final d in widget.days) d.day],
        today: widget.today,
        highlightIndex: _tapped,
        onTap: _select,
        semanticValues: <String>[for (final v in values) '$v milliliters'],
      ),
    );
  }
}

class _WaterBarsPainter extends _BarChartPainter {
  _WaterBarsPainter({
    required this.values,
    required this.scaleMax,
    required this.goalMl,
    required this.highlightIndex,
    required this.labelIndices,
    required this.barColor,
    required this.gridColor,
    required this.mutedColor,
    required this.labelColor,
    required this.bubbleColor,
    required this.onBubbleColor,
  });

  final List<int> values;
  final double scaleMax;
  final int goalMl;
  final int? highlightIndex;
  final Set<int> labelIndices;
  final Color barColor;
  final Color gridColor;
  final Color mutedColor;
  final Color labelColor;
  final Color bubbleColor;
  final Color onBubbleColor;

  double _barHeight(int i, double barAreaHeight) =>
      scaleMax <= 0 ? 0.0 : (values[i] / scaleMax) * barAreaHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final top = _topLabelPad;
    final barAreaHeight = size.height - top;
    final baseline = size.height;

    drawHorizontalGrid(canvas, size, top, barAreaHeight, gridColor);

    if (goalMl > 0) {
      final y = top + barAreaHeight * (1 - (goalMl / scaleMax));
      drawDashedLine(canvas, size.width, y, mutedColor);
      drawRightLabel(canvas, 'goal', Offset(size.width, y - 2), mutedColor);
    }

    final columnWidth = size.width / values.length;
    final barWidth = (columnWidth - _minBarGap * 2).clamp(8.0, _maxBarWidth);

    for (var i = 0; i < values.length; i++) {
      final centerX = columnWidth * (i + 0.5);
      final height = _barHeight(i, barAreaHeight);
      final rrect = RRect.fromRectAndCorners(
        Rect.fromLTRB(centerX - barWidth / 2, baseline - height, centerX + barWidth / 2, baseline),
        topLeft: const Radius.circular(4),
        topRight: const Radius.circular(4),
      );
      canvas.drawRRect(rrect, Paint()..color = barColor);
      if (i == highlightIndex) {
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = labelColor.withValues(alpha: 0.5)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }

    for (final i in labelIndices) {
      if (i == highlightIndex) continue;
      final centerX = columnWidth * (i + 0.5);
      final height = _barHeight(i, barAreaHeight);
      drawCenteredLabel(canvas, '${values[i]}', Offset(centerX, baseline - height - 6), labelColor);
    }
    if (highlightIndex != null) {
      final i = highlightIndex!;
      final centerX = columnWidth * (i + 0.5);
      final height = _barHeight(i, barAreaHeight);
      drawBubble(
        canvas,
        '${values[i]} ml',
        Offset(centerX, baseline - height - 10),
        bg: bubbleColor,
        fg: onBubbleColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaterBarsPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.scaleMax != scaleMax ||
      oldDelegate.goalMl != goalMl ||
      oldDelegate.highlightIndex != highlightIndex ||
      oldDelegate.labelIndices != labelIndices ||
      oldDelegate.barColor != barColor ||
      oldDelegate.gridColor != gridColor;
}

// ---------------------------------------------------------------------------
// Weekly adherence — DESIGN.md §Charts "Weekly adherence"
// ---------------------------------------------------------------------------

/// Per-day % taken as a [DD.teal] fill over a full-height `cardAlt` track —
/// the untaken remainder is absence, not a colored series ("no red/green
/// stacking"). Labels today and the best day only.
class AdherenceWeekChart extends StatefulWidget {
  const AdherenceWeekChart({
    super.key,
    required this.days,
    required this.today,
    required this.onDayTap,
  });

  /// Exactly 7 entries, Monday first (as returned by `adherenceByDay`).
  final List<AdherenceDay> days;
  final DateTime today;
  final ValueChanged<DateTime> onDayTap;

  @override
  State<AdherenceWeekChart> createState() => _AdherenceWeekChartState();
}

class _AdherenceWeekChartState extends State<AdherenceWeekChart> {
  int? _tapped;

  void _select(int index) {
    setState(() => _tapped = index);
    widget.onDayTap(widget.days[index].day);
  }

  @override
  void didUpdateWidget(covariant AdherenceWeekChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.days.first.day != widget.days.first.day) _tapped = null;
  }

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final fractions = <double?>[
      for (final d in widget.days)
        d.adherence.total == 0 ? null : d.adherence.taken / d.adherence.total,
    ];

    final todayIndex = widget.days.indexWhere((d) => _sameDay(d.day, widget.today));
    var bestIndex = -1;
    var bestValue = -1.0;
    for (var i = 0; i < fractions.length; i++) {
      final f = fractions[i];
      if (f != null && f > bestValue) {
        bestValue = f;
        bestIndex = i;
      }
    }
    final labelIndices = <int>{
      if (todayIndex >= 0) todayIndex,
      if (bestIndex >= 0) bestIndex,
    };

    return _ChartCard(
      chart: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => _select(
                _indexForX(details.localPosition.dx, constraints.maxWidth, fractions.length)),
            child: CustomPaint(
              size: Size(constraints.maxWidth, _chartHeight),
              painter: _AdherenceBarsPainter(
                fractions: fractions,
                highlightIndex: _tapped,
                labelIndices: labelIndices,
                fillColor: DD.teal,
                trackColor: t.cardAlt,
                gridColor: t.outline,
                labelColor: t.ink,
                bubbleColor: t.ink,
                onBubbleColor: t.bg,
              ),
            ),
          ),
        ),
      ),
      axis: _DayLetterAxis(
        days: <DateTime>[for (final d in widget.days) d.day],
        today: widget.today,
        highlightIndex: _tapped,
        onTap: _select,
        semanticValues: <String>[
          for (final f in fractions)
            f == null ? 'nothing scheduled' : '${(f * 100).round()} percent taken',
        ],
      ),
    );
  }
}

class _AdherenceBarsPainter extends _BarChartPainter {
  _AdherenceBarsPainter({
    required this.fractions,
    required this.highlightIndex,
    required this.labelIndices,
    required this.fillColor,
    required this.trackColor,
    required this.gridColor,
    required this.labelColor,
    required this.bubbleColor,
    required this.onBubbleColor,
  });

  /// 0..1 taken fraction, or `null` when nothing was scheduled that day.
  final List<double?> fractions;
  final int? highlightIndex;
  final Set<int> labelIndices;
  final Color fillColor;
  final Color trackColor;
  final Color gridColor;
  final Color labelColor;
  final Color bubbleColor;
  final Color onBubbleColor;

  @override
  void paint(Canvas canvas, Size size) {
    final top = _topLabelPad;
    final barAreaHeight = size.height - top;
    final baseline = size.height;

    drawHorizontalGrid(canvas, size, top, barAreaHeight, gridColor);

    final columnWidth = size.width / fractions.length;
    final barWidth = (columnWidth - _minBarGap * 2).clamp(8.0, _maxBarWidth);

    for (var i = 0; i < fractions.length; i++) {
      final centerX = columnWidth * (i + 0.5);
      final trackRRect = RRect.fromRectAndCorners(
        Rect.fromLTRB(centerX - barWidth / 2, top, centerX + barWidth / 2, baseline),
        topLeft: const Radius.circular(4),
        topRight: const Radius.circular(4),
      );
      canvas.drawRRect(trackRRect, Paint()..color = trackColor);

      final fraction = fractions[i] ?? 0.0;
      if (fraction > 0) {
        final fillHeight = barAreaHeight * fraction;
        final fillRRect = RRect.fromRectAndCorners(
          Rect.fromLTRB(centerX - barWidth / 2, baseline - fillHeight, centerX + barWidth / 2, baseline),
          topLeft: const Radius.circular(4),
          topRight: const Radius.circular(4),
        );
        canvas.drawRRect(fillRRect, Paint()..color = fillColor);
      }

      if (i == highlightIndex) {
        canvas.drawRRect(
          trackRRect,
          Paint()
            ..color = labelColor.withValues(alpha: 0.5)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }

    for (final i in labelIndices) {
      if (i == highlightIndex) continue;
      final fraction = fractions[i];
      if (fraction == null) continue;
      final centerX = columnWidth * (i + 0.5);
      final fillHeight = barAreaHeight * fraction;
      drawCenteredLabel(
        canvas,
        '${(fraction * 100).round()}%',
        Offset(centerX, baseline - fillHeight - 6),
        labelColor,
      );
    }
    if (highlightIndex != null) {
      final i = highlightIndex!;
      final fraction = fractions[i] ?? 0.0;
      final centerX = columnWidth * (i + 0.5);
      final fillHeight = barAreaHeight * fraction;
      drawBubble(
        canvas,
        '${(fraction * 100).round()}%',
        Offset(centerX, baseline - fillHeight - 10),
        bg: bubbleColor,
        fg: onBubbleColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AdherenceBarsPainter oldDelegate) =>
      oldDelegate.fractions != fractions ||
      oldDelegate.highlightIndex != highlightIndex ||
      oldDelegate.labelIndices != labelIndices ||
      oldDelegate.fillColor != fillColor ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.gridColor != gridColor;
}
