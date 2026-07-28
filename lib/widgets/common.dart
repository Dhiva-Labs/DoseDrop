/// Small, shared, presentational widgets used across every screen.
///
/// Nothing here talks to [AppState] directly — screens compute the data
/// (status, colors, callbacks) and hand it down, so these stay easy to reuse
/// and to preview in isolation.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../models/models.dart';
import '../theme/app_theme.dart';

/// `HapticFeedback.lightImpact()` for confirm-taken actions (DESIGN.md "Haptic
/// light impact on confirm"). Android only — other platforms either lack the
/// vibration motor UX (desktop) or already have their own conventions.
void triggerConfirmHaptic() {
  if (!kIsWeb && Platform.isAndroid) {
    HapticFeedback.lightImpact();
  }
}

/// DESIGN.md "Touch targets ≥ 48px" for the Material buttons whose default
/// theme is shorter than that. `app_theme.dart` already themes
/// [FilledButton]/[TextButton] up to 48px; [OutlinedButton] and
/// [SegmentedButton] are left at Material's smaller default, so screens pass
/// this explicitly wherever they use one.
const ButtonStyle kMinTouchButtonStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll<Size>(Size(48, 48)),
);

// ---------------------------------------------------------------------------
// Dose status → icon/label/color (DESIGN.md §Palette "Status" table)
// ---------------------------------------------------------------------------

/// The icon, label and color for one dose's current status.
///
/// Status is always shown as icon **and** label — DESIGN.md: "status never
/// used as series/identity colors; always icon + label, never color alone".
class DoseStatusVisual {
  const DoseStatusVisual({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  /// The look for a bare [DoseStatus] (no snooze context).
  factory DoseStatusVisual.of(DDTheme t, DoseStatus status) {
    switch (status) {
      case DoseStatus.taken:
        return DoseStatusVisual(
            icon: Icons.check_circle, label: 'Taken', color: t.taken);
      case DoseStatus.skipped:
        return DoseStatusVisual(
            icon: Icons.remove_circle_outline,
            label: 'Skipped',
            color: t.skipped);
      case DoseStatus.missed:
        return DoseStatusVisual(
            icon: Icons.error, label: 'Missed', color: t.missed);
      case DoseStatus.pending:
        return DoseStatusVisual(
            icon: Icons.schedule, label: 'Pending', color: t.ink3);
    }
  }

  /// [of] a slot's record, plus the "Snoozed" look while the snooze is still
  /// ahead of [now] — once the snoozed time itself arrives the dose is due
  /// again, so it reads as pending/overdue rather than snoozed.
  factory DoseStatusVisual.forSlot(
    DDTheme t, {
    required DoseRecord? record,
    required DateTime effectiveDue,
    required DateTime now,
  }) {
    if (record != null && record.isSnoozed && now.isBefore(effectiveDue)) {
      return DoseStatusVisual(
          icon: Icons.snooze, label: 'Snoozed', color: t.snoozed);
    }
    return DoseStatusVisual.of(t, record?.status ?? DoseStatus.pending);
  }
}

/// A small icon + label pill in [color] — the only way status is ever shown.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    this.dense = false,
  });

  factory StatusPill.visual(DoseStatusVisual visual, {bool dense = false}) =>
      StatusPill(
        icon: visual.icon,
        label: visual.label,
        color: visual.color,
        dense: dense,
      );

  final IconData icon;
  final String label;
  final Color color;

  /// Slightly smaller, for tight rows (e.g. inside a due-now card header).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: dense ? 12 : 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: dense ? 11 : 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SectionHeader
// ---------------------------------------------------------------------------

/// H2 label for a section within a screen, with an optional trailing widget.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// EmptyState
// ---------------------------------------------------------------------------

/// 96px soft circle + icon, one encouraging line, optional primary CTA.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.ctaLabel,
    this.onCta,
  });

  final IconData icon;
  final String message;
  final String? ctaLabel;
  final VoidCallback? onCta;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: DD.pad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(color: t.cardAlt, shape: BoxShape.circle),
              child: Icon(icon, size: 40, color: t.ink3),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: t.ink2),
            ),
            if (ctaLabel != null) ...<Widget>[
              const SizedBox(height: 20),
              FilledButton(onPressed: onCta, child: Text(ctaLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Day-letter row (Mon..Sun) — read-only display or interactive toggle
// ---------------------------------------------------------------------------

const List<String> _dayLetters = <String>['M', 'T', 'W', 'T', 'F', 'S', 'S'];
const List<String> _dayFullNames = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// Mon–Sun letter dots. Read-only when [onChanged] is `null` (med list
/// cards); tappable toggles otherwise (MedEditSheet).
class DayLetterRow extends StatelessWidget {
  const DayLetterRow({super.key, required this.days, this.onChanged});

  /// `DateTime.monday` (1) … `DateTime.sunday` (7).
  final Set<int> days;
  final ValueChanged<Set<int>>? onChanged;

  @override
  Widget build(BuildContext context) {
    final interactive = onChanged != null;
    return Row(
      children: <Widget>[
        for (var i = 0; i < 7; i++)
          Expanded(
            child: _DayDot(
              label: _dayLetters[i],
              semanticLabel: _dayFullNames[i],
              active: days.contains(i + 1),
              interactive: interactive,
              onTap: interactive ? () => _toggle(i + 1) : null,
            ),
          ),
      ],
    );
  }

  void _toggle(int weekday) {
    final next = <int>{...days};
    if (!next.remove(weekday)) next.add(weekday);
    onChanged?.call(next);
  }
}

class _DayDot extends StatelessWidget {
  const _DayDot({
    required this.label,
    required this.semanticLabel,
    required this.active,
    required this.interactive,
    required this.onTap,
  });

  final String label;
  final String semanticLabel;
  final bool active;
  final bool interactive;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final dot = Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? DD.teal : t.cardAlt,
        shape: BoxShape.circle,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 13,
          color: active ? DD.onTeal : t.ink2,
        ),
      ),
    );
    // 48px minimum touch target even though the visible dot is smaller.
    final cell = SizedBox(height: 48, child: Center(child: dot));

    return Semantics(
      label: semanticLabel,
      button: interactive,
      toggled: interactive ? active : null,
      excludeSemantics: true,
      child: interactive
          ? InkWell(
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: cell,
            )
          : cell,
    );
  }
}

// ---------------------------------------------------------------------------
// StepperRow — labeled numeric -/+ control (Water + Settings screens)
// ---------------------------------------------------------------------------

/// A label (plus optional subtitle), a live value, and -/+ buttons.
///
/// Shared by the Water screen's goal/cup/interval rows and the Settings
/// screen's nag interval/count/grace window rows, so both read the same way.
class StepperRow extends StatelessWidget {
  const StepperRow({
    super.key,
    required this.label,
    required this.valueLabel,
    required this.onDecrement,
    required this.onIncrement,
    this.subtitle,
  });

  final String label;
  final String valueLabel;
  final String? subtitle;

  /// `null` disables the button (value already at its floor/ceiling).
  final VoidCallback? onDecrement;
  final VoidCallback? onIncrement;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(label, style: Theme.of(context).textTheme.bodyMedium),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!,
                        style: TextStyle(color: t.ink3, fontSize: 12)),
                  ),
              ],
            ),
          ),
          _StepButton(
            icon: Icons.remove,
            onTap: onDecrement,
            semanticLabel: 'Decrease $label',
          ),
          SizedBox(
            width: 68,
            child: Text(
              valueLabel,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: DD.tabular,
                  ),
            ),
          ),
          _StepButton(
            icon: Icons.add,
            onTap: onIncrement,
            semanticLabel: 'Increase $label',
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.onTap,
    required this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final enabled = onTap != null;
    return Tooltip(
      message: semanticLabel,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Material(
          color: t.cardAlt,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Icon(
              icon,
              size: 18,
              color: enabled ? t.ink : t.ink3.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TimeChip
// ---------------------------------------------------------------------------

/// A small `"HH:mm"` pill; shows a remove affordance when [onDeleted] is set.
class TimeChip extends StatelessWidget {
  const TimeChip({
    super.key,
    required this.time,
    this.onDeleted,
    this.selected = false,
  });

  final String time;
  final VoidCallback? onDeleted;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final bg = selected ? DD.teal.withValues(alpha: 0.14) : t.cardAlt;
    final fg = selected ? DD.teal : t.ink;
    return Container(
      padding: EdgeInsets.fromLTRB(10, 6, onDeleted != null ? 4 : 10, 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            time,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: fg,
              fontFeatures: DD.tabular,
            ),
          ),
          if (onDeleted != null) ...<Widget>[
            const SizedBox(width: 2),
            Tooltip(
              message: 'Remove $time',
              child: Semantics(
                label: 'Remove $time',
                button: true,
                excludeSemantics: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: onDeleted,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(Icons.close, size: 14, color: fg),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
