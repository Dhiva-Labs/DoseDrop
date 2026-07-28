import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'med_edit_sheet.dart';
import 'settings_screen.dart';

/// "Meds" (DESIGN.md §Screens.2): a list of medication cards and a FAB that
/// opens [MedEditSheet] to add a new one; tapping a card edits it in place.
class MedsScreen extends StatelessWidget {
  const MedsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final meds = context.watch<AppState>().meds;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(DD.pad),
          children: <Widget>[
            const _Header(),
            const SizedBox(height: DD.gap),
            if (meds.isEmpty)
              EmptyState(
                icon: Icons.medication_outlined,
                message:
                    'No medications yet. Add one to start tracking your doses.',
                ctaLabel: 'Add your first medication',
                onCta: () => openMedEditSheet(context),
              )
            else
              for (final med in meds) _MedListCard(med: med),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => openMedEditSheet(context),
        tooltip: 'Add medication',
        child: const Icon(Icons.add),
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
          child: Text('Meds', style: Theme.of(context).textTheme.displaySmall),
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

class _MedListCard extends StatelessWidget {
  const _MedListCard({required this.med});

  final Medication med;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final state = context.read<AppState>();
    final color = t.medColor(med.colorIndex);
    final dosage = med.dosage.trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: t.card,
        borderRadius: BorderRadius.circular(DD.rCard),
        child: InkWell(
          borderRadius: BorderRadius.circular(DD.rCard),
          onTap: () => openMedEditSheet(context, med: med),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(DD.rCard),
              border: Border.all(color: t.outline),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.medication,
                          color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            med.name,
                            style: Theme.of(context).textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (dosage.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 2),
                            Text(
                              dosage,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(color: t.ink2),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Semantics(
                      label: '${med.name} reminders',
                      toggled: med.enabled,
                      excludeSemantics: true,
                      child: Switch(
                        value: med.enabled,
                        onChanged: (v) => state.toggleMed(med.id, enabled: v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (med.sortedTimes.isEmpty)
                  Text(
                    'No times set',
                    style: TextStyle(color: t.ink3, fontSize: 13),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final time in med.sortedTimes) TimeChip(time: time),
                    ],
                  ),
                const SizedBox(height: 12),
                DayLetterRow(days: med.days),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
