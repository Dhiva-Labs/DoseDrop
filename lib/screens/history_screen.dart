import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';
import '../services/schedule_engine.dart';
import '../theme/app_theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import 'settings_screen.dart';

/// "History" (DESIGN.md §Screens.4): a week pager, stat tiles (current
/// streak, best streak, 7-day adherence), the weekly adherence + water
/// charts, and a day-detail sheet when a bar or day chip is tapped.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late DateTime _weekStart;

  @override
  void initState() {
    super.initState();
    _weekStart = _mondayOf(DateTime.now());
  }

  static DateTime _mondayOf(DateTime date) {
    final start = Days.startOf(date);
    return Days.add(start, -(start.weekday - 1));
  }

  void _previousWeek() => setState(() => _weekStart = Days.add(_weekStart, -7));

  void _nextWeek(DateTime now) {
    final currentWeekStart = _mondayOf(now);
    if (!_weekStart.isBefore(currentWeekStart)) return; // already the newest week
    setState(() => _weekStart = Days.add(_weekStart, 7));
  }

  void _openDayDetail(AppState state, List<WaterDay> waterByDay, DateTime day) {
    final slots = ScheduleEngine.slotsForDay(state.meds, day);
    final water = waterByDay.firstWhere(
      (e) => Days.same(e.day, day),
      orElse: () => (day: day, ml: 0),
    );
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _DayDetailSheet(
        day: day,
        slots: slots,
        recordFor: state.recordFor,
        now: state.now,
        waterMl: water.ml,
        waterGoalMl: state.waterSettings.goalMl,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      body: SafeArea(
        child: state.meds.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(DD.pad),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const <Widget>[
                    _Header(),
                    Expanded(
                      child: EmptyState(
                        icon: Icons.bar_chart_outlined,
                        message: 'Your history will appear here',
                      ),
                    ),
                  ],
                ),
              )
            : _content(context, state),
      ),
    );
  }

  Widget _content(BuildContext context, AppState state) {
    final weekEnd = Days.add(_weekStart, 6);
    final waterByDay = state.waterMlByDay(_weekStart, weekEnd);
    final adherenceByDay = state.adherenceByDay(_weekStart, weekEnd);
    final atCurrentWeek = _weekStart.isAtSameMomentAs(_mondayOf(state.now));

    return ListView(
      padding: const EdgeInsets.all(DD.pad),
      children: <Widget>[
        const _Header(),
        const SizedBox(height: DD.gap),
        _WeekPager(
          start: _weekStart,
          end: weekEnd,
          onPrevious: _previousWeek,
          onNext: atCurrentWeek ? null : () => _nextWeek(state.now),
        ),
        const SizedBox(height: DD.gap),
        _StatTilesRow(state: state),
        const SizedBox(height: DD.gap),
        const SectionHeader(title: 'Adherence'),
        AdherenceWeekChart(
          days: adherenceByDay,
          today: state.now,
          onDayTap: (day) => _openDayDetail(state, waterByDay, day),
        ),
        const SizedBox(height: DD.gap),
        const SectionHeader(title: 'Water'),
        WaterWeekChart(
          days: waterByDay,
          goalMl: state.waterSettings.goalMl,
          today: state.now,
          onDayTap: (day) => _openDayDetail(state, waterByDay, day),
        ),
      ],
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
          child: Text('History', style: Theme.of(context).textTheme.displaySmall),
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

// ---------------------------------------------------------------------------
// Week pager
// ---------------------------------------------------------------------------

class _WeekPager extends StatelessWidget {
  const _WeekPager({
    required this.start,
    required this.end,
    required this.onPrevious,
    required this.onNext,
  });

  final DateTime start;
  final DateTime end;
  final VoidCallback onPrevious;

  /// `null` disables the button — DESIGN.md: can't page into the future.
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final sameMonth = start.month == end.month && start.year == end.year;
    final fmt = DateFormat(sameMonth ? 'EEE d' : 'EEE MMM d');
    final label = '${fmt.format(start)} – ${fmt.format(end)}';

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        IconButton(
          tooltip: 'Previous week',
          icon: const Icon(Icons.chevron_left),
          onPressed: onPrevious,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontFeatures: DD.tabular),
          ),
        ),
        IconButton(
          tooltip: 'Next week',
          icon: const Icon(Icons.chevron_right),
          onPressed: onNext,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Stat tiles — current streak, best streak, 7-day adherence (rolling, as of
// today — independent of whichever week is currently paged in above).
// ---------------------------------------------------------------------------

class _StatTilesRow extends StatelessWidget {
  const _StatTilesRow({required this.state});

  final AppState state;

  Adherence _rolling7Days() {
    final today = Days.startOf(state.now);
    final from = Days.add(today, -6);
    var taken = 0;
    var total = 0;
    for (final row in state.adherenceByDay(from, today)) {
      taken += row.adherence.taken;
      total += row.adherence.total;
    }
    return (taken: taken, total: total);
  }

  @override
  Widget build(BuildContext context) {
    final rolling = _rolling7Days();
    final pct = rolling.total == 0 ? null : (rolling.taken / rolling.total * 100).round();

    return Row(
      children: <Widget>[
        Expanded(
          child: _StatTile(
            emoji: '🔥',
            value: '${state.currentStreak}',
            label: 'Current streak',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatTile(
            icon: Icons.emoji_events_outlined,
            value: '${state.bestStreak}',
            label: 'Best streak',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatTile(
            icon: Icons.check_circle_outline,
            value: pct == null ? '—' : '$pct%',
            label: '7-day adherence',
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({this.emoji, this.icon, required this.value, required this.label})
      : assert(emoji != null || icon != null, 'need an emoji or an icon');

  final String? emoji;
  final IconData? icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    return Semantics(
      label: '$label, $value',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: BorderRadius.circular(DD.rTile),
          border: Border.all(color: t.outline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (emoji != null)
              Text(emoji!, style: const TextStyle(fontSize: 18))
            else
              Icon(icon, size: 18, color: t.ink3),
            const SizedBox(height: 6),
            Text(
              value,
              style: Theme.of(context)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(fontFeatures: DD.tabular),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: t.ink2),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Day detail sheet
// ---------------------------------------------------------------------------

class _DayDetailSheet extends StatelessWidget {
  const _DayDetailSheet({
    required this.day,
    required this.slots,
    required this.recordFor,
    required this.now,
    required this.waterMl,
    required this.waterGoalMl,
  });

  final DateTime day;
  final List<DoseSlot> slots;
  final DoseRecord? Function(String key) recordFor;
  final DateTime now;
  final int waterMl;
  final int waterGoalMl;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final media = MediaQuery.of(context);

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.85),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(DD.pad, 12, DD.pad, DD.pad),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: t.outline,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                DateFormat('EEEE, MMMM d').format(day),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: t.cardAlt,
                  borderRadius: BorderRadius.circular(DD.rCard),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.water_drop, color: DD.water),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Water', style: Theme.of(context).textTheme.bodyMedium),
                    ),
                    Text(
                      '$waterMl / $waterGoalMl ml',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontFeatures: DD.tabular,
                        color: t.ink,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const SectionHeader(title: 'Doses'),
              if (slots.isEmpty)
                Text(
                  'Nothing scheduled this day.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.ink2),
                )
              else
                for (final slot in slots) _doseRow(context, t, slot),
            ],
          ),
        ),
      ),
    );
  }

  Widget _doseRow(BuildContext context, DDTheme t, DoseSlot slot) {
    final record = recordFor(slot.key);
    final due = ScheduleEngine.effectiveDue(slot, record);
    final visual = DoseStatusVisual.forSlot(t, record: record, effectiveDue: due, now: now);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: t.medColor(slot.med.colorIndex),
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(Icons.medication, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  slot.med.name,
                  style: Theme.of(context).textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  slot.time,
                  style: TextStyle(color: t.ink3, fontSize: 12, fontFeatures: DD.tabular),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          StatusPill.visual(visual),
        ],
      ),
    );
  }
}
