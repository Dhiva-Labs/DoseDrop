import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// Opens [MedEditSheet] as a modal bottom sheet. Pass [med] to edit an
/// existing medication; omit it to create a new one.
Future<void> openMedEditSheet(BuildContext context, {Medication? med}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => MedEditSheet(existing: med),
  );
}

/// Bottom-sheet editor (DESIGN.md §Screens.2 "MedEditSheet"): name, dosage,
/// 6-swatch color picker, times list, Mon–Sun day toggles, notes, Save —
/// plus delete-with-confirm when editing an existing medication.
class MedEditSheet extends StatefulWidget {
  const MedEditSheet({super.key, this.existing});

  /// `null` creates a new medication; otherwise this one is edited in place.
  final Medication? existing;

  @override
  State<MedEditSheet> createState() => _MedEditSheetState();
}

class _MedEditSheetState extends State<MedEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _dosage;
  late final TextEditingController _notes;
  late int _colorIndex;
  late List<String> _times;
  late Set<int> _days;
  late bool _enabled;
  bool _triedSubmit = false;

  bool get _isEditing => widget.existing != null;
  bool get _nameValid => _name.text.trim().isNotEmpty;
  bool get _timesValid => _times.isNotEmpty;
  bool get _daysValid => _days.isNotEmpty;
  bool get _isValid => _nameValid && _timesValid && _daysValid;

  @override
  void initState() {
    super.initState();
    final m = widget.existing;
    _name = TextEditingController(text: m?.name ?? '');
    _dosage = TextEditingController(text: m?.dosage ?? '');
    _notes = TextEditingController(text: m?.notes ?? '');
    _colorIndex = m?.colorIndex ?? 0;
    _times = <String>[...(m?.sortedTimes ?? const <String>[])];
    _days = <int>{...(m?.days ?? Medication.everyDay)};
    _enabled = m?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _dosage.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final media = MediaQuery.of(context);

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.92),
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
                _isEditing ? 'Edit medication' : 'New medication',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Name',
                  errorText: _triedSubmit && !_nameValid ? 'Enter a name' : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _dosage,
                decoration: const InputDecoration(
                  labelText: 'Dosage',
                  hintText: 'e.g. 500 mg · 1 tablet',
                ),
              ),
              const SizedBox(height: 20),
              const SectionHeader(title: 'Color'),
              _ColorPicker(
                selected: _colorIndex,
                onChanged: (i) => setState(() => _colorIndex = i),
              ),
              const SizedBox(height: 20),
              SectionHeader(
                title: 'Times',
                trailing: TextButton.icon(
                  onPressed: _addTime,
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
              ),
              if (_times.isEmpty)
                Text(
                  _triedSubmit ? 'Add at least one time' : 'No times yet',
                  style: TextStyle(
                    color: _triedSubmit ? t.missed : t.ink3,
                    fontSize: 13,
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final time in _times)
                      TimeChip(
                        time: time,
                        onDeleted: () => setState(() => _times.remove(time)),
                      ),
                  ],
                ),
              const SizedBox(height: 20),
              const SectionHeader(title: 'Repeats on'),
              DayLetterRow(
                days: _days,
                onChanged: (d) => setState(() => _days = d),
              ),
              if (_triedSubmit && !_daysValid)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Choose at least one day',
                    style: TextStyle(color: t.missed, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 20),
              TextField(
                controller: _notes,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
                title: const Text('Enabled'),
                subtitle: const Text('Off pauses reminders for this medication'),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _save,
                  child: Text(_isEditing ? 'Save changes' : 'Add medication'),
                ),
              ),
              if (_isEditing) ...<Widget>[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: _confirmDelete,
                    style: TextButton.styleFrom(foregroundColor: t.missed),
                    child: const Text('Delete medication'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked == null) return;
    final formatted = HhMm.format(picked.hour * 60 + picked.minute);
    if (_times.contains(formatted)) return;
    setState(() {
      _times = <String>[..._times, formatted]..sort(HhMm.compare);
    });
  }

  void _save() {
    setState(() => _triedSubmit = true);
    if (!_isValid) return;

    final state = context.read<AppState>();
    final name = _name.text.trim();
    final dosage = _dosage.text.trim();
    final notes = _notes.text.trim();

    if (_isEditing) {
      state.updateMed(widget.existing!.copyWith(
        name: name,
        dosage: dosage,
        colorIndex: _colorIndex,
        times: _times,
        days: _days,
        notes: notes,
        enabled: _enabled,
      ));
    } else {
      state.addMed(
        name: name,
        dosage: dosage,
        colorIndex: _colorIndex,
        times: _times,
        days: _days,
        notes: notes,
        enabled: _enabled,
      );
    }
    Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete medication?'),
        content: Text(
          "This removes ${existing.name} and its dose history. This can't be undone.",
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DDTheme.of(dialogContext).missed,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    context.read<AppState>().deleteMed(existing.id);
    Navigator.of(context).pop();
  }
}

class _ColorPicker extends StatelessWidget {
  const _ColorPicker({required this.selected, required this.onChanged});

  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = DDTheme.of(context);
    final colors = t.medColors;
    return Row(
      children: <Widget>[
        for (var i = 0; i < colors.length; i++)
          Expanded(
            child: Semantics(
              label: 'Color ${i + 1}',
              button: true,
              selected: selected == i,
              excludeSemantics: true,
              child: InkWell(
                onTap: () => onChanged(i),
                customBorder: const CircleBorder(),
                child: SizedBox(
                  height: 48,
                  child: Center(
                    child: Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: colors[i],
                        shape: BoxShape.circle,
                        border: selected == i
                            ? Border.all(color: t.ink, width: 2.5)
                            : null,
                      ),
                      child: selected == i
                          ? const Icon(Icons.check, color: Colors.white, size: 16)
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
