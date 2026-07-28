import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

const int _minNagIntervalMin = 1;
const int _maxNagIntervalMin = 60;
const int _maxNagCount = 10;
const int _minGraceMin = 5;
const int _maxGraceMin = 240;
const int _graceStepMin = 5;

/// "Settings" (DESIGN.md §Screens.5): reminder behavior, alarm sound, theme,
/// desktop autostart, pause/resume, test notification, and the about block.
///
/// Pushed from the gear icon on each main screen, so — unlike the four tab
/// roots with their large One UI-style headers — this one uses a regular
/// `AppBar` for the standard back affordance.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final settings = state.settings;
    final showAutostart = !kIsWeb && (Platform.isLinux || Platform.isWindows);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(DD.pad),
          children: <Widget>[
            const SectionHeader(title: 'Reminder behavior'),
            _SettingsCard(
              children: <Widget>[
                StepperRow(
                  label: 'Nag interval',
                  subtitle: 'How often an unconfirmed dose re-alerts',
                  valueLabel: '${settings.nagIntervalMin} min',
                  onDecrement: settings.nagIntervalMin > _minNagIntervalMin
                      ? () => _update(
                          state,
                          settings.copyWith(
                            nagIntervalMin: settings.nagIntervalMin - 1,
                          ),
                        )
                      : null,
                  onIncrement: settings.nagIntervalMin < _maxNagIntervalMin
                      ? () => _update(
                          state,
                          settings.copyWith(
                            nagIntervalMin: settings.nagIntervalMin + 1,
                          ),
                        )
                      : null,
                ),
                _divider(context),
                StepperRow(
                  label: 'Nag count',
                  subtitle: 'Re-alerts sent after the first notification',
                  valueLabel: '${settings.nagMaxCount}',
                  onDecrement: settings.nagMaxCount > 0
                      ? () => _update(
                          state,
                          settings.copyWith(
                            nagMaxCount: settings.nagMaxCount - 1,
                          ),
                        )
                      : null,
                  onIncrement: settings.nagMaxCount < _maxNagCount
                      ? () => _update(
                          state,
                          settings.copyWith(
                            nagMaxCount: settings.nagMaxCount + 1,
                          ),
                        )
                      : null,
                ),
                _divider(context),
                StepperRow(
                  label: 'Grace window',
                  subtitle: "Time before an unconfirmed dose is marked missed",
                  valueLabel: '${settings.graceMin} min',
                  onDecrement: settings.graceMin > _minGraceMin
                      ? () => _update(
                          state,
                          settings.copyWith(
                            graceMin: settings.graceMin - _graceStepMin,
                          ),
                        )
                      : null,
                  onIncrement: settings.graceMin < _maxGraceMin
                      ? () => _update(
                          state,
                          settings.copyWith(
                            graceMin: settings.graceMin + _graceStepMin,
                          ),
                        )
                      : null,
                ),
                _divider(context),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: settings.alarmSound,
                  onChanged: (v) =>
                      _update(state, settings.copyWith(alarmSound: v)),
                  title: const Text('Alarm sound'),
                  subtitle: const Text('Loop a sound until you respond'),
                ),
              ],
            ),
            const SizedBox(height: DD.gap),
            const SectionHeader(title: 'Appearance'),
            _SettingsCard(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: _ThemeModePicker(
                    mode: settings.themeMode,
                    onChanged: (m) =>
                        _update(state, settings.copyWith(themeMode: m)),
                  ),
                ),
              ],
            ),
            if (showAutostart) ...<Widget>[
              const SizedBox(height: DD.gap),
              const SectionHeader(title: 'Desktop'),
              _SettingsCard(
                children: <Widget>[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: settings.autostart,
                    onChanged: (v) =>
                        _update(state, settings.copyWith(autostart: v)),
                    title: const Text('Start DoseDrop at login'),
                    subtitle: const Text(
                      'Closing the window keeps DoseDrop running in the tray so '
                      'reminders keep firing — use the tray menu to quit.',
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: DD.gap),
            const SectionHeader(title: 'Reminders'),
            _SettingsCard(
              children: <Widget>[
                _PauseRow(state: state),
                _divider(context),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: const Text('Send test notification'),
                  subtitle: const Text(
                    'Confirm reminders are working on this device',
                  ),
                  onTap: () => _sendTest(context, state),
                ),
              ],
            ),
            const SizedBox(height: DD.gap),
            const _About(),
          ],
        ),
      ),
    );
  }

  Widget _divider(BuildContext context) =>
      Divider(height: 1, color: DDTheme.of(context).outline);

  static void _update(AppState state, AppSettings next) =>
      state.updateSettings(next);

  static Future<void> _sendTest(BuildContext context, AppState state) async {
    await state.sendTestNotification();
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Test notification sent')));
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      // ListTile descendants paint ink on the nearest Material; without this
      // the decorated Container above would hide it (and assert in debug).
      child: Material(
        type: MaterialType.transparency,
        child: Column(children: children),
      ),
    );
  }
}

class _ThemeModePicker extends StatelessWidget {
  const _ThemeModePicker({required this.mode, required this.onChanged});

  final AppThemeMode mode;
  final ValueChanged<AppThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text('Theme', style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 10),
        SegmentedButton<AppThemeMode>(
          segments: const <ButtonSegment<AppThemeMode>>[
            ButtonSegment<AppThemeMode>(
              value: AppThemeMode.system,
              label: Text('System'),
            ),
            ButtonSegment<AppThemeMode>(
              value: AppThemeMode.light,
              label: Text('Light'),
            ),
            ButtonSegment<AppThemeMode>(
              value: AppThemeMode.dark,
              label: Text('Dark'),
            ),
          ],
          selected: <AppThemeMode>{mode},
          onSelectionChanged: (selection) => onChanged(selection.first),
          style: kMinTouchButtonStyle,
        ),
      ],
    );
  }
}

class _PauseRow extends StatelessWidget {
  const _PauseRow({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final paused = state.isPaused;
    final until = state.settings.pausedUntil;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          Icon(
            paused
                ? Icons.notifications_paused_outlined
                : Icons.notifications_active_outlined,
            color: t.ink2,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  paused ? 'Reminders paused' : 'Reminders are active',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (paused && until != null)
                  Text(
                    'Until ${HhMm.fromDateTime(until)}',
                    style: TextStyle(color: t.ink3, fontSize: 12),
                  ),
              ],
            ),
          ),
          if (paused)
            FilledButton(
              onPressed: state.resumeReminders,
              child: const Text('Resume'),
            )
          else
            OutlinedButton(
              style: kMinTouchButtonStyle,
              onPressed: () => state.pauseReminders(),
              child: const Text('Pause 1 hour'),
            ),
        ],
      ),
    );
  }
}

class _About extends StatelessWidget {
  const _About();

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: <Widget>[
            const Icon(Icons.water_drop, color: DD.teal, size: 28),
            const SizedBox(height: 8),
            Text('DoseDrop', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              'v1.0.0',
              style: TextStyle(
                color: t.ink3,
                fontSize: 12,
                fontFeatures: DD.tabular,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Your tablets & water, on time.',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.ink2, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
