import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/water_ring.dart';
import 'settings_screen.dart';

/// "Water" (DESIGN.md §Screens.3): the full ring, a quick-add row, today's
/// undoable log, and inline settings (goal, cup size, interval, active
/// hours, enable toggle).
class WaterScreen extends StatelessWidget {
  const WaterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ws = state.waterSettings;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(DD.pad),
          children: <Widget>[
            const _Header(),
            const SizedBox(height: DD.gap),
            if (!ws.enabled) ...<Widget>[
              _DisabledBanner(
                onEnable: () =>
                    state.updateWaterSettings(ws.copyWith(enabled: true)),
              ),
              const SizedBox(height: DD.gap),
            ],
            Center(
              child: WaterRing(
                currentMl: state.todayWaterMl,
                goalMl: ws.goalMl,
                size: 180,
              ),
            ),
            const SizedBox(height: 20),
            _QuickAddRow(state: state),
            const SizedBox(height: DD.gap),
            const SectionHeader(title: "Today's log"),
            _WaterLog(state: state),
            const SizedBox(height: DD.gap),
            const SectionHeader(title: 'Settings'),
            _InlineWaterSettings(state: state, settings: ws),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text('Water', style: Theme.of(context).textTheme.displaySmall),
        ),
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
          ),
        ),
      ],
    );
  }
}

class _DisabledBanner extends StatelessWidget {
  const _DisabledBanner({required this.onEnable});

  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.cardAlt,
        borderRadius: BorderRadius.circular(DD.rCard),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.notifications_off_outlined, color: t.ink2),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Water reminders are off. You can still log water manually.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: t.ink2),
            ),
          ),
          TextButton(onPressed: onEnable, child: const Text('Turn on')),
        ],
      ),
    );
  }
}

class _QuickAddRow extends StatelessWidget {
  const _QuickAddRow({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final cup = state.waterSettings.cupMl;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        FilledButton.icon(
          onPressed: () => state.addWater(),
          icon: const Icon(Icons.add),
          label: Text('+$cup ml'),
        ),
        OutlinedButton(
          style: kMinTouchButtonStyle,
          onPressed: () => state.addWater(500),
          child: const Text('+500 ml'),
        ),
        OutlinedButton(
          style: kMinTouchButtonStyle,
          onPressed: () => _customAmount(context),
          child: const Text('Custom…'),
        ),
      ],
    );
  }

  Future<void> _customAmount(BuildContext context) async {
    final controller = TextEditingController();
    try {
      final result = await showDialog<int>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Add water'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Amount (ml)'),
            onSubmitted: (value) =>
                Navigator.of(dialogContext).pop(int.tryParse(value.trim())),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(int.tryParse(controller.text.trim())),
              child: const Text('Add'),
            ),
          ],
        ),
      );
      if (result != null && result > 0) {
        state.addWater(result);
      }
    } finally {
      controller.dispose();
    }
  }
}

class _WaterLog extends StatelessWidget {
  const _WaterLog({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final entries = state.waterEntriesToday.reversed.toList();

    if (entries.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: BorderRadius.circular(DD.rCard),
          border: Border.all(color: t.outline),
        ),
        child: Text(
          'No water logged yet today.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: t.ink2),
        ),
      );
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(DD.rCard),
        border: Border.all(color: t.outline),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: <Widget>[
          for (var i = 0; i < entries.length; i++) ...<Widget>[
            if (i > 0) Divider(height: 1, color: t.outline),
            _logRow(context, t, entries[i], undoable: i == 0),
          ],
        ],
      ),
    );
  }

  Widget _logRow(
    BuildContext context,
    DDTheme t,
    WaterEntry entry, {
    required bool undoable,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          Icon(Icons.water_drop, color: t.waterAccent, size: 18),
          const SizedBox(width: 10),
          Text(
            HhMm.fromDateTime(entry.at),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontFeatures: DD.tabular),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${entry.ml} ml',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: t.ink2),
            ),
          ),
          if (undoable)
            TextButton(
              onPressed: state.undoLastWater,
              child: const Text('Undo'),
            ),
        ],
      ),
    );
  }
}

class _InlineWaterSettings extends StatelessWidget {
  const _InlineWaterSettings({required this.state, required this.settings});

  final AppState state;
  final WaterSettings settings;

  static const int _goalStepMl = 100;
  static const int _minGoalMl = 500;
  static const int _cupStepMl = 50;
  static const int _minCupMl = 50;
  static const int _intervalStepMin = 15;
  static const int _minIntervalMin = 15;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(DD.rCard),
        border: Border.all(color: t.outline),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      // ListTile descendants paint ink on the nearest Material; without this
      // the decorated Container above would hide it (and assert in debug).
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: <Widget>[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: settings.enabled,
              onChanged: (v) =>
                  state.updateWaterSettings(settings.copyWith(enabled: v)),
              title: const Text('Water reminders'),
              subtitle: const Text('Nudge me to drink during active hours'),
            ),
            Divider(height: 1, color: t.outline),
            StepperRow(
              label: 'Daily goal',
              valueLabel: '${settings.goalMl} ml',
              onDecrement: settings.goalMl - _goalStepMl >= _minGoalMl
                  ? () => state.updateWaterSettings(
                      settings.copyWith(goalMl: settings.goalMl - _goalStepMl),
                    )
                  : null,
              onIncrement: () => state.updateWaterSettings(
                settings.copyWith(goalMl: settings.goalMl + _goalStepMl),
              ),
            ),
            Divider(height: 1, color: t.outline),
            StepperRow(
              label: 'Cup size',
              valueLabel: '${settings.cupMl} ml',
              onDecrement: settings.cupMl - _cupStepMl >= _minCupMl
                  ? () => state.updateWaterSettings(
                      settings.copyWith(cupMl: settings.cupMl - _cupStepMl),
                    )
                  : null,
              onIncrement: () => state.updateWaterSettings(
                settings.copyWith(cupMl: settings.cupMl + _cupStepMl),
              ),
            ),
            Divider(height: 1, color: t.outline),
            StepperRow(
              label: 'Reminder interval',
              valueLabel: '${settings.intervalMin} min',
              onDecrement:
                  settings.intervalMin - _intervalStepMin >= _minIntervalMin
                  ? () => state.updateWaterSettings(
                      settings.copyWith(
                        intervalMin: settings.intervalMin - _intervalStepMin,
                      ),
                    )
                  : null,
              onIncrement: () => state.updateWaterSettings(
                settings.copyWith(
                  intervalMin: settings.intervalMin + _intervalStepMin,
                ),
              ),
            ),
            Divider(height: 1, color: t.outline),
            _ActiveHoursRow(state: state, settings: settings),
          ],
        ),
      ),
    );
  }
}

class _ActiveHoursRow extends StatelessWidget {
  const _ActiveHoursRow({required this.state, required this.settings});

  final AppState state;
  final WaterSettings settings;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              'Active hours',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          OutlinedButton(
            style: kMinTouchButtonStyle,
            onPressed: () => _pick(context, isStart: true),
            child: Text(
              settings.activeStartLabel,
              style: const TextStyle(fontFeatures: DD.tabular),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text('–', style: TextStyle(color: t.ink3)),
          ),
          OutlinedButton(
            style: kMinTouchButtonStyle,
            onPressed: () => _pick(context, isStart: false),
            child: Text(
              settings.activeEndLabel,
              style: const TextStyle(fontFeatures: DD.tabular),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pick(BuildContext context, {required bool isStart}) async {
    final initialMinutes = isStart
        ? settings.activeStartMin
        : settings.activeEndMin;
    final safeMinutes = initialMinutes.clamp(0, HhMm.minutesPerDay - 1);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: safeMinutes ~/ 60, minute: safeMinutes % 60),
    );
    if (picked == null) return;
    final minutes = picked.hour * 60 + picked.minute;
    state.updateWaterSettings(
      isStart
          ? settings.copyWith(activeStartMin: minutes)
          : settings.copyWith(activeEndMin: minutes),
    );
  }
}
