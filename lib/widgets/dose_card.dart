import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/app_theme.dart';
import 'common.dart';

/// Which look [DoseCard] renders (DESIGN.md §Components "DoseCard").
enum DoseCardStyle {
  /// Quiet row: chip, name, "dosage · HH:mm", trailing status pill. No
  /// action buttons — used for doses that are not currently actionable.
  list,

  /// Just became due: card elevates, border in the med's identity color,
  /// full actions row.
  dueNow,

  /// Still unresolved well past its due time: thin `missed`-color border and
  /// an explicit "Overdue" pill, same actions as [dueNow].
  overdue,
}

/// A single dose: identity chip, name, dosage/time, status — and, when
/// [style] is actionable, "Mark as taken" / "Snooze 10 min" / "Skip".
class DoseCard extends StatelessWidget {
  const DoseCard({
    super.key,
    required this.slot,
    required this.record,
    required this.effectiveDue,
    required this.now,
    this.style = DoseCardStyle.list,
    this.onTaken,
    this.onSnooze,
    this.onSkip,
  });

  final DoseSlot slot;
  final DoseRecord? record;

  /// When this slot is actually due (honours an active snooze).
  final DateTime effectiveDue;

  /// The clock the screen is ticking on (`AppState.now`), for snooze display.
  final DateTime now;

  final DoseCardStyle style;

  /// Required (along with [onSnooze], [onSkip]) when [style] is not [list].
  final VoidCallback? onTaken;
  final VoidCallback? onSnooze;
  final VoidCallback? onSkip;

  bool get _actionable => style != DoseCardStyle.list;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final medColor = t.medColor(slot.med.colorIndex);
    final borderColor = switch (style) {
      DoseCardStyle.list => t.outline,
      DoseCardStyle.dueNow => medColor,
      DoseCardStyle.overdue => t.missed,
    };
    final borderWidth = switch (style) {
      DoseCardStyle.list => 1.0,
      DoseCardStyle.dueNow => 2.0,
      DoseCardStyle.overdue => 1.5,
    };

    return Container(
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(DD.rCard),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: _actionable
            ? <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: t.isDark ? 0.24 : 0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              _MedChip(color: medColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      slot.med.name,
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: t.ink2),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _pill(t),
            ],
          ),
          if (_actionable) ...<Widget>[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onTaken,
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Mark as taken'),
              ),
            ),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextButton.icon(
                    onPressed: onSnooze,
                    icon: const Icon(Icons.snooze, size: 18),
                    label: const Text('Snooze 10 min'),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: onSkip,
                    icon: const Icon(Icons.remove_circle_outline, size: 18),
                    label: const Text('Skip'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _pill(DDTheme t) {
    switch (style) {
      case DoseCardStyle.overdue:
        return StatusPill(icon: Icons.error, label: 'Overdue', color: t.missed);
      case DoseCardStyle.dueNow:
        return StatusPill(icon: Icons.schedule, label: 'Due now', color: t.ink2);
      case DoseCardStyle.list:
        return StatusPill.visual(DoseStatusVisual.forSlot(
          t,
          record: record,
          effectiveDue: effectiveDue,
          now: now,
        ));
    }
  }

  String get _subtitle {
    final dosage = slot.med.dosage.trim();
    return dosage.isEmpty ? slot.time : '$dosage · ${slot.time}';
  }
}

class _MedChip extends StatelessWidget {
  const _MedChip({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
      child: const Icon(Icons.medication, color: Colors.white, size: 22),
    );
  }
}
