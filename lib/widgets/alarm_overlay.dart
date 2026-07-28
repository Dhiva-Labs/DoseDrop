import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';
import '../services/desktop_reminder_engine.dart' show ReminderKind;
import '../theme/app_theme.dart';
import 'common.dart';

/// Full-screen ringing reminder (DESIGN.md §Components "AlarmOverlay").
///
/// Dose: pulsing ring in the med's color around a 96px chip, med name
/// (Display), dosage + time, huge "Mark as taken", "Snooze 10 min" / "Skip".
/// Water: "Sip time! 💧" in the water accent, "Log `<cup>` ml" primary,
/// "Dismiss" secondary. The looping alarm sound is owned by `AppState`/
/// `AlarmSound` — this widget only renders and reports the user's choice.
class AlarmOverlay extends StatefulWidget {
  const AlarmOverlay({super.key, required this.alarm});

  final ActiveAlarm alarm;

  @override
  State<AlarmOverlay> createState() => _AlarmOverlayState();
}

class _AlarmOverlayState extends State<AlarmOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final alarm = widget.alarm;
    final isWater = alarm.kind == ReminderKind.water;
    final med = alarm.slot?.med;
    final accent = isWater
        ? t.waterAccent
        : (med != null ? t.medColor(med.colorIndex) : DD.teal);

    return Material(
      color: t.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(DD.pad),
          child: Column(
            children: <Widget>[
              const Spacer(),
              _PulsingChip(
                color: accent,
                pulse: _pulse,
                icon: isWater ? Icons.water_drop : Icons.medication,
              ),
              const SizedBox(height: 32),
              Text(
                isWater ? 'Sip time! 💧' : (med?.name ?? 'Dose reminder'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.displaySmall,
              ),
              const SizedBox(height: 8),
              Text(
                _subtitle(alarm, isWater: isWater, med: med),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: t.ink2,
                      fontFeatures: DD.tabular,
                    ),
              ),
              const Spacer(),
              _AlarmActions(alarm: alarm, isWater: isWater),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  String _subtitle(ActiveAlarm alarm, {required bool isWater, Medication? med}) {
    final time = HhMm.fromDateTime(alarm.at);
    if (isWater) return 'Scheduled for $time';
    final dosage = med?.dosage.trim() ?? '';
    return dosage.isEmpty ? 'Scheduled for $time' : '$dosage · $time';
  }
}

class _PulsingChip extends StatelessWidget {
  const _PulsingChip({
    required this.color,
    required this.pulse,
    required this.icon,
  });

  final Color color;
  final Animation<double> pulse;
  final IconData icon;

  static const double _chipSize = 96;
  static const double _fieldSize = 180;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _fieldSize,
      height: _fieldSize,
      child: AnimatedBuilder(
        animation: pulse,
        builder: (context, _) {
          final progress = pulse.value;
          final scale = 1.0 + progress * 0.6;
          final opacity = (1.0 - progress).clamp(0.0, 1.0);
          return Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Transform.scale(
                scale: scale,
                child: Opacity(
                  opacity: opacity * 0.45,
                  child: Container(
                    width: _chipSize,
                    height: _chipSize,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                  ),
                ),
              ),
              Container(
                width: _chipSize,
                height: _chipSize,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                child: Icon(icon, color: Colors.white, size: 44),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AlarmActions extends StatelessWidget {
  const _AlarmActions({required this.alarm, required this.isWater});

  final ActiveAlarm alarm;
  final bool isWater;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();

    if (isWater) {
      final cup = state.waterSettings.cupMl;
      return Column(
        children: <Widget>[
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
              ),
              onPressed: () => state.dismissAlarm(AlarmAction.taken),
              child: Text('Log $cup ml'),
            ),
          ),
          TextButton(
            onPressed: () => state.dismissAlarm(AlarmAction.dismiss),
            child: const Text('Dismiss'),
          ),
        ],
      );
    }

    return Column(
      children: <Widget>[
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
            onPressed: () {
              triggerConfirmHaptic();
              state.dismissAlarm(AlarmAction.taken);
            },
            child: const Text('Mark as taken'),
          ),
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: TextButton(
                onPressed: () => state.dismissAlarm(AlarmAction.snooze),
                child: const Text('Snooze 10 min'),
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: () => state.dismissAlarm(AlarmAction.skip),
                child: const Text('Skip'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
