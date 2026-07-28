import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/dose_card.dart';
import '../widgets/water_ring.dart';
import 'med_edit_sheet.dart';
import 'settings_screen.dart';

/// "Today" (DESIGN.md §Screens.1): large header + friendly date, NextUp
/// hero with a live countdown, "Due now" dose cards, a compact water card,
/// and a compact timeline of the whole day.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final hasMeds = state.meds.isNotEmpty;
    final next = state.nextDose;
    final dueNow = state.dueNow;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(DD.pad),
          children: <Widget>[
            _Header(now: state.now),
            const SizedBox(height: DD.gap),
            if (!hasMeds)
              EmptyState(
                icon: Icons.medication_outlined,
                message:
                    'No medications yet. Add one to start tracking your doses.',
                ctaLabel: 'Add your first medication',
                onCta: () => openMedEditSheet(context),
              )
            else ...<Widget>[
              next == null
                  ? const _AllDoneHero()
                  : _NextUpHero(
                      slot: next,
                      due: state.effectiveDueOf(next),
                      now: state.now,
                    ),
              if (dueNow.isNotEmpty) ...<Widget>[
                const SizedBox(height: DD.gap),
                const SectionHeader(title: 'Due now'),
                for (final slot in dueNow) _DueNowTile(slot: slot),
              ],
            ],
            const SizedBox(height: DD.gap),
            const SectionHeader(title: 'Water'),
            _HomeWaterCard(state: state),
            if (hasMeds) ...<Widget>[
              const SizedBox(height: DD.gap),
              const SectionHeader(title: "Today's timeline"),
              _TodayTimeline(state: state),
            ],
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.now});

  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Today', style: Theme.of(context).textTheme.displaySmall),
              const SizedBox(height: 4),
              Text(
                DateFormat('EEEE, MMMM d').format(now),
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: t.ink2),
              ),
            ],
          ),
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

class _NextUpHero extends StatelessWidget {
  const _NextUpHero({required this.slot, required this.due, required this.now});

  final DoseSlot slot;
  final DateTime due;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final dosage = slot.med.dosage.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: DD.heroGradient,
        borderRadius: BorderRadius.circular(DD.rCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'NEXT UP',
            style: TextStyle(
              color: DD.onTeal.withValues(alpha: 0.8),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            slot.med.name,
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(color: DD.onTeal),
          ),
          if (dosage.isNotEmpty) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              dosage,
              style: TextStyle(
                color: DD.onTeal.withValues(alpha: 0.85),
                fontSize: 15,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Icon(Icons.schedule,
                  size: 16, color: DD.onTeal.withValues(alpha: 0.85)),
              const SizedBox(width: 6),
              Text(
                slot.time,
                style: TextStyle(
                  color: DD.onTeal.withValues(alpha: 0.85),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  fontFeatures: DD.tabular,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _countdown(due.difference(now)),
                style: const TextStyle(
                  color: DD.onTeal,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  fontFeatures: DD.tabular,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _countdown(Duration remaining) {
    if (remaining.inSeconds <= 0) return 'now';
    if (remaining.inHours >= 1) {
      final h = remaining.inHours;
      final m = remaining.inMinutes % 60;
      return 'in ${h}h ${m.toString().padLeft(2, '0')}m';
    }
    if (remaining.inMinutes >= 1) return 'in ${remaining.inMinutes}m';
    return 'in ${remaining.inSeconds}s';
  }
}

class _AllDoneHero extends StatelessWidget {
  const _AllDoneHero();

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
        color: t.cardAlt,
        borderRadius: BorderRadius.circular(DD.rCard),
      ),
      child: Column(
        children: <Widget>[
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: t.card, shape: BoxShape.circle),
            child: const Icon(Icons.check_circle_outline,
                color: DD.teal, size: 32),
          ),
          const SizedBox(height: 12),
          Text('All done for today 🎉',
              style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _DueNowTile extends StatelessWidget {
  const _DueNowTile({required this.slot});

  final DoseSlot slot;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final due = state.effectiveDueOf(slot);
    final nagMinutes = state.settings.nagIntervalMin;
    final overdueAt = nagMinutes > 0 ? due.add(Duration(minutes: nagMinutes)) : due;
    final overdue = !state.now.isBefore(overdueAt);

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DoseCard(
        slot: slot,
        record: state.recordFor(slot.key),
        effectiveDue: due,
        now: state.now,
        style: overdue ? DoseCardStyle.overdue : DoseCardStyle.dueNow,
        onTaken: () {
          triggerConfirmHaptic();
          state.confirmTaken(slot.key);
        },
        onSnooze: () => state.snooze(slot.key),
        onSkip: () => state.skip(slot.key),
      ),
    );
  }
}

class _HomeWaterCard extends StatelessWidget {
  const _HomeWaterCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final ws = state.waterSettings;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(DD.rCard),
        border: Border.all(color: t.outline),
      ),
      child: ws.enabled ? _content(context, t, ws) : _disabledPrompt(context, t),
    );
  }

  Widget _disabledPrompt(BuildContext context, DDTheme t) {
    return Row(
      children: <Widget>[
        Icon(Icons.water_drop_outlined, color: t.ink3, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Water tracking is off',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.ink2),
          ),
        ),
        TextButton(
          onPressed: () => state
              .updateWaterSettings(state.waterSettings.copyWith(enabled: true)),
          child: const Text('Turn on'),
        ),
      ],
    );
  }

  Widget _content(BuildContext context, DDTheme t, WaterSettings ws) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        WaterRing(
          currentMl: state.todayWaterMl,
          goalMl: ws.goalMl,
          size: 104,
          strokeWidth: 10,
          compact: true,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              OutlinedButton(
                style: kMinTouchButtonStyle,
                onPressed: () => state.addWater(),
                child: Text('+${ws.cupMl} ml'),
              ),
              OutlinedButton(
                style: kMinTouchButtonStyle,
                onPressed: () => state.addWater(500),
                child: const Text('+500 ml'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TodayTimeline extends StatelessWidget {
  const _TodayTimeline({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final slots = state.todaySlots;

    if (slots.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: BorderRadius.circular(DD.rCard),
          border: Border.all(color: t.outline),
        ),
        child: Text(
          'Nothing scheduled for today.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: t.ink2),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(DD.rCard),
        border: Border.all(color: t.outline),
      ),
      child: Column(
        children: <Widget>[
          for (final slot in slots) _row(context, t, slot),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, DDTheme t, DoseSlot slot) {
    final record = state.recordFor(slot.key);
    final due = state.effectiveDueOf(slot);
    final visual = DoseStatusVisual.forSlot(
      t,
      record: record,
      effectiveDue: due,
      now: state.now,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 48,
            child: Text(
              slot.time,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: t.ink3, fontFeatures: DD.tabular),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(color: visual.color, shape: BoxShape.circle),
            child: Icon(visual.icon, size: 12, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              slot.med.name,
              style: Theme.of(context).textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
