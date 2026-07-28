import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'alarm_sound.dart';
import 'desktop_reminder_engine.dart';
import 'notification_service.dart';
import 'schedule_engine.dart';
import 'storage_service.dart';
import 'tray_service.dart';

/// What the user chose on the alarm overlay (or a notification action).
enum AlarmAction {
  taken,
  snooze,
  skip,

  /// Close the alarm without recording anything (water "Dismiss").
  dismiss,
}

/// A reminder currently ringing inside the app.
class ActiveAlarm {
  const ActiveAlarm({
    required this.kind,
    required this.at,
    this.slot,
    this.nag = 0,
  });

  ActiveAlarm.fromFire(ReminderFire fire)
      : kind = fire.kind,
        at = fire.at,
        slot = fire.slot,
        nag = fire.nag;

  final ReminderKind kind;

  /// The due (or nag) instant that raised this alarm.
  final DateTime at;

  /// The dose, when [kind] is [ReminderKind.dose].
  final DoseSlot? slot;

  /// 0 for the first alert, 1..n for escalating nags.
  final int nag;

  /// Identity used to avoid stacking the same alarm twice.
  String get key => switch (kind) {
        ReminderKind.dose => 'dose#${slot?.key}',
        ReminderKind.water => 'water#${DoseKey.dayString(at)}'
            '#${HhMm.fromDateTime(at)}',
      };
}

/// Folds changes another writer made to the data file into the running app's
/// state, returning `null` when there is nothing to take over.
///
/// The Android background isolate resolves doses and logs water straight to disk
/// while the app is alive (action buttons declare `showsUserInterface: false`, so
/// Android routes them there rather than to the UI isolate). Without this merge
/// the app's next save would quietly undo the user's tap.
///
/// Merge rules — deliberately conservative, since the isolate only ever *adds*
/// resolutions:
/// * a dose the app still thinks is pending, but which disk records as
///   taken/skipped/missed, is taken from disk;
/// * a snooze recorded on disk wins over an unresolved in-memory record;
/// * water entries present on disk but not in memory are appended;
/// * nothing already resolved in memory is ever overwritten, and meds and
///   settings are left alone — the isolate never touches them.
AppData? mergeExternalChanges(AppData mine, AppData onDisk) {
  var changed = false;

  final records = <String, DoseRecord>{...mine.records};
  for (final entry in onDisk.records.entries) {
    final ours = records[entry.key];
    final theirs = entry.value;
    if (ours != null && ours.status.isActed) continue;
    final takesOver = theirs.status.isActed ||
        (theirs.snoozedUntil != null && theirs.snoozedUntil != ours?.snoozedUntil);
    if (!takesOver) continue;
    records[entry.key] = theirs;
    changed = true;
  }

  String waterId(WaterEntry entry) => '${entry.at.toIso8601String()}#${entry.ml}';
  final known = mine.water.map(waterId).toSet();
  final water = <WaterEntry>[
    ...mine.water,
    for (final entry in onDisk.water)
      if (known.add(waterId(entry))) entry,
  ];
  if (water.length != mine.water.length) changed = true;

  if (!changed) return null;
  return mine.copyWith(records: records, water: water);
}

/// The single API the UI talks to (PLAN.md "AppState API").
///
/// Owns [AppData] and wires together storage, the schedule engine,
/// notifications, the desktop reminder engine, the alarm sound and the tray.
/// Every mutation follows the same path: change state → persist → reschedule
/// notifications → `notifyListeners()`.
class AppState extends ChangeNotifier {
  AppState({
    required this._storage,
    required this._notifications,
    this._alarmSound,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final StorageService _storage;
  final NotificationService _notifications;
  final AlarmSound? _alarmSound;
  final Uuid _uuid;

  DesktopReminderEngine? _desktop;
  TrayService? _tray;

  Timer? _uiTimer;
  Timer? _sweepTimer;

  AppData _data = AppData.empty;
  DateTime _now = DateTime.now();
  String _uiSignature = '';
  bool _isLoaded = false;
  DateTime? _lastKnownMtime;
  final List<ActiveAlarm> _alarms = <ActiveAlarm>[];

  /// How often missed doses are swept.
  static const Duration sweepInterval = Duration(seconds: 30);

  /// How often [now] advances for countdowns.
  static const Duration uiTickInterval = Duration(seconds: 1);

  /// How long the tray's "Pause 1 hour" lasts.
  static const Duration pauseDuration = Duration(hours: 1);

  // -------------------------------------------------------------------------
  // Snapshot
  // -------------------------------------------------------------------------

  /// The full persisted state. Read-only; mutate through the methods below.
  AppData get data => _data;

  List<Medication> get meds => _data.meds;
  AppSettings get settings => _data.settings;
  WaterSettings get waterSettings => _data.waterSettings;

  /// Clock shared by the UI so every countdown ticks together.
  DateTime get now => _now;

  bool get isLoaded => _isLoaded;

  /// True while reminders are paused (tray "Pause 1 hour").
  bool get isPaused => settings.isPausedAt(_now);

  /// The reminder currently ringing in-app, if any.
  ActiveAlarm? get activeAlarm => _alarms.isEmpty ? null : _alarms.first;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Loads state from disk and starts everything.
  Future<void> load() async {
    _data = await _storage.load();
    _lastKnownMtime = await _storage.lastModified();
    _isLoaded = true;
    _now = DateTime.now();

    _notifications.setActionHandler(_onNotificationAction);
    await _alarmSound?.prepare();

    // Anything that expired while the app was away.
    await _sweepMissed(persist: false);
    await _notifications.rescheduleAll(_data);

    if (DesktopReminderEngine.isSupported) {
      _desktop = DesktopReminderEngine(
        notifications: _notifications,
        snapshot: () => _data,
        onFire: _onDesktopFire,
      )..start();
    }
    if (AutostartService.isSupported) {
      await AutostartService.apply(enabled: settings.autostart);
    }

    _uiTimer ??= Timer.periodic(uiTickInterval, (_) => _onUiTick());
    _sweepTimer ??= Timer.periodic(sweepInterval, (_) => unawaited(_onSweep()));

    _uiSignature = _computeUiSignature();
    notifyListeners();
  }

  /// Lets the tray call back into the app (set from `main`).
  void attachTray(TrayService tray) => _tray = tray;

  /// Applies the notification the app was launched from, if any.
  Future<void> handleLaunch() async {
    final launch = await _notifications.launchPayload();
    if (launch == null) return;
    _onNotificationAction(launch.payload, launch.actionId);
  }

  /// Flushes state — call before quitting from the tray.
  Future<void> flush() async {
    await _storage.save(_data);
    await _alarmSound?.stop();
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _sweepTimer?.cancel();
    _desktop?.dispose();
    unawaited(_alarmSound?.dispose() ?? Future<void>.value());
    _notifications.setActionHandler(null);
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Medications
  // -------------------------------------------------------------------------

  /// Creates a medication, generating its id.
  Future<Medication> addMed({
    required String name,
    String dosage = '',
    int colorIndex = 0,
    List<String> times = const <String>[],
    Set<int> days = Medication.everyDay,
    String notes = '',
    bool enabled = true,
  }) async {
    final med = Medication(
      id: _uuid.v4(),
      name: name,
      dosage: dosage,
      colorIndex: colorIndex,
      times: times,
      days: days,
      notes: notes,
      enabled: enabled,
    );
    await _mutate(_data.copyWith(meds: <Medication>[..._data.meds, med]));
    return med;
  }

  /// Replaces the medication with the same id.
  Future<void> updateMed(Medication med) async {
    final meds = <Medication>[
      for (final existing in _data.meds)
        if (existing.id == med.id) med else existing,
    ];
    await _mutate(_data.copyWith(meds: meds));
  }

  /// Deletes a medication and the dose history that belonged to it.
  ///
  /// Its records are dropped on purpose: with the med gone there are no slots
  /// to attach them to, so they could never be shown again.
  Future<void> deleteMed(String id) async {
    final prefix = '$id${DoseKey.separator}';
    await _mutate(_data.copyWith(
      meds: <Medication>[
        for (final med in _data.meds)
          if (med.id != id) med,
      ],
      records: <String, DoseRecord>{
        for (final entry in _data.records.entries)
          if (!entry.key.startsWith(prefix)) entry.key: entry.value,
      },
    ));
  }

  /// Flips a medication's enabled flag.
  Future<void> toggleMed(String id, {bool? enabled}) async {
    final med = _data.medById(id);
    if (med == null) return;
    await updateMed(med.copyWith(enabled: enabled ?? !med.enabled));
  }

  // -------------------------------------------------------------------------
  // Doses
  // -------------------------------------------------------------------------

  /// Every dose scheduled today, in time order.
  List<DoseSlot> get todaySlots => ScheduleEngine.slotsForDay(meds, _now);

  /// Doses that should be alerting right now, oldest first.
  List<DoseSlot> get dueNow =>
      ScheduleEngine.dueNow(meds, _data.records, _now, settings.grace);

  /// The next unresolved dose at or after [now].
  DoseSlot? get nextDose => ScheduleEngine.nextDose(meds, _data.records, _now);

  /// The record for a dose key, or `null` when it is untouched.
  DoseRecord? recordFor(String key) => _data.records[key];

  /// When a slot is actually due, honouring an active snooze.
  DateTime effectiveDueOf(DoseSlot slot) =>
      ScheduleEngine.effectiveDue(slot, _data.records[slot.key]);

  /// Marks a dose taken.
  Future<void> confirmTaken(String key) =>
      _resolveDose(key, DoseStatus.taken);

  /// Marks a dose skipped.
  Future<void> skip(String key) => _resolveDose(key, DoseStatus.skipped);

  /// Pushes a dose out by [AppSettings.snoozeMinutes], keeping it pending.
  Future<void> snooze(String key) async {
    final until = DateTime.now().add(settings.snooze);
    final existing = _data.records[key];
    final record = (existing ?? DoseRecord(key: key)).copyWith(
      status: DoseStatus.pending,
      snoozedUntil: until,
      clearActedAt: true,
    );
    await _notifications.cancelSlot(key, nagCount: settings.nagMaxCount);
    // The snooze creates fresh due/nag points, so let the desktop engine ring
    // again for this slot.
    _desktop?.forgetSlot(key);
    _clearAlarmFor('dose#$key');
    await _mutate(_data.copyWith(records: <String, DoseRecord>{
      ..._data.records,
      key: record,
    }));
  }

  Future<void> _resolveDose(String key, DoseStatus status) async {
    final record = DoseRecord(
      key: key,
      status: status,
      actedAt: DateTime.now(),
    );
    await _notifications.cancelSlot(key, nagCount: settings.nagMaxCount);
    _clearAlarmFor('dose#$key');
    await _mutate(_data.copyWith(records: <String, DoseRecord>{
      ..._data.records,
      key: record,
    }));
  }

  // -------------------------------------------------------------------------
  // Water
  // -------------------------------------------------------------------------

  /// Total ml logged today.
  int get todayWaterMl => ScheduleEngine.waterMlForDay(_data.water, _now);

  /// Today's drinks, oldest first.
  List<WaterEntry> get waterEntriesToday => <WaterEntry>[
        for (final entry in _data.water)
          if (Days.same(entry.at, _now)) entry,
      ]..sort((a, b) => a.at.compareTo(b.at));

  /// Logs a drink; defaults to [WaterSettings.cupMl].
  Future<void> addWater([int? ml]) async {
    final amount = ml ?? waterSettings.cupMl;
    if (amount <= 0) return;
    _clearAlarmKind(ReminderKind.water);
    await _mutate(_data.copyWith(water: <WaterEntry>[
      ..._data.water,
      WaterEntry(at: DateTime.now(), ml: amount),
    ]));
  }

  /// Removes the most recent drink (today's if there is one).
  Future<void> undoLastWater() async {
    if (_data.water.isEmpty) return;
    var index = -1;
    DateTime? latest;
    for (var i = 0; i < _data.water.length; i++) {
      final at = _data.water[i].at;
      if (latest == null || !at.isBefore(latest)) {
        latest = at;
        index = i;
      }
    }
    if (index < 0) return;
    final water = <WaterEntry>[..._data.water]..removeAt(index);
    await _mutate(_data.copyWith(water: water));
  }

  Future<void> updateWaterSettings(WaterSettings settings) =>
      _mutate(_data.copyWith(waterSettings: settings));

  // -------------------------------------------------------------------------
  // Settings
  // -------------------------------------------------------------------------

  /// Saves settings, applying the autostart side effect when it changed.
  Future<void> updateSettings(AppSettings next) async {
    final autostartChanged = next.autostart != settings.autostart;
    final alarmDisabled = !next.alarmSound && settings.alarmSound;
    await _mutate(_data.copyWith(settings: next));
    if (autostartChanged) {
      await AutostartService.apply(enabled: next.autostart);
    }
    if (alarmDisabled) await _alarmSound?.stop();
  }

  /// Suppresses reminders for [duration] (tray "Pause 1 hour").
  Future<void> pauseReminders([Duration duration = pauseDuration]) async {
    await _alarmSound?.stop();
    _alarms.clear();
    await updateSettings(
      settings.copyWith(pausedUntil: DateTime.now().add(duration)),
    );
  }

  /// Cancels a pause immediately.
  Future<void> resumeReminders() =>
      updateSettings(settings.copyWith(clearPausedUntil: true));

  /// Fires a notification so the user can confirm reminders work.
  Future<void> sendTestNotification() =>
      _notifications.sendTestNotification();

  // -------------------------------------------------------------------------
  // History / stats
  // -------------------------------------------------------------------------

  /// Dose records whose day falls in `[from, to]` (inclusive, by calendar day).
  Map<String, DoseRecord> recordsForRange(DateTime from, DateTime to) {
    final start = Days.startOf(from);
    final end = Days.startOf(to);
    return <String, DoseRecord>{
      for (final entry in _data.records.entries)
        if (_dayOfKeyInRange(entry.key, start, end)) entry.key: entry.value,
    };
  }

  /// Water totals per day across `[from, to]`, ordered oldest first.
  List<({DateTime day, int ml})> waterMlByDay(DateTime from, DateTime to) {
    final days = Days.diffInDays(from, to);
    return <({DateTime day, int ml})>[
      for (var i = 0; i <= days; i++)
        (
          day: Days.add(from, i),
          ml: ScheduleEngine.waterMlForDay(_data.water, Days.add(from, i)),
        ),
    ];
  }

  /// Adherence per day across `[from, to]`, ordered oldest first.
  List<({DateTime day, Adherence adherence})> adherenceByDay(
    DateTime from,
    DateTime to,
  ) {
    final days = Days.diffInDays(from, to);
    return <({DateTime day, Adherence adherence})>[
      for (var i = 0; i <= days; i++)
        (
          day: Days.add(from, i),
          adherence: ScheduleEngine.adherenceForDay(
            meds,
            _data.records,
            Days.add(from, i),
          ),
        ),
    ];
  }

  /// Consecutive fully-taken days ending today (see `ScheduleEngine`).
  int get currentStreak =>
      ScheduleEngine.currentStreak(meds, _data.records, _now);

  /// Longest fully-taken run in the recorded history.
  int get bestStreak => ScheduleEngine.bestStreak(meds, _data.records, _now);

  bool _dayOfKeyInRange(String key, DateTime start, DateTime end) {
    final parts = DoseKey.tryParse(key);
    if (parts == null) return false;
    return !parts.day.isBefore(start) && !parts.day.isAfter(end);
  }

  // -------------------------------------------------------------------------
  // Alarms
  // -------------------------------------------------------------------------

  /// Resolves the ringing alarm with the user's choice and stops the sound.
  Future<void> dismissAlarm(AlarmAction action) async {
    final alarm = activeAlarm;
    if (alarm == null) return;
    _alarms.removeAt(0);
    if (_alarms.isEmpty) await _alarmSound?.stop();

    switch (alarm.kind) {
      case ReminderKind.dose:
        final key = alarm.slot?.key;
        if (key == null) break;
        switch (action) {
          case AlarmAction.taken:
            await confirmTaken(key);
          case AlarmAction.skip:
            await skip(key);
          case AlarmAction.snooze:
            await snooze(key);
          case AlarmAction.dismiss:
            notifyListeners();
        }
      case ReminderKind.water:
        if (action == AlarmAction.taken) {
          await addWater();
        } else {
          notifyListeners();
        }
    }
  }

  void _onDesktopFire(ReminderFire fire) {
    final alarm = ActiveAlarm.fromFire(fire);
    if (_alarms.any((existing) => existing.key == alarm.key)) return;
    _alarms.add(alarm);
    if (settings.alarmSound) unawaited(_alarmSound?.startLoop());
    notifyListeners();
  }

  void _clearAlarmFor(String key) {
    final removed = _alarms.length;
    _alarms.removeWhere((alarm) => alarm.key == key);
    if (_alarms.isEmpty && removed > 0) unawaited(_alarmSound?.stop());
  }

  void _clearAlarmKind(ReminderKind kind) {
    final removed = _alarms.length;
    _alarms.removeWhere((alarm) => alarm.kind == kind);
    if (_alarms.isEmpty && removed > 0) unawaited(_alarmSound?.stop());
  }

  // -------------------------------------------------------------------------
  // Notification actions (foreground)
  // -------------------------------------------------------------------------

  /// Applies a notification tap/action that arrived while the app is alive.
  ///
  /// Actions taken with the app closed are handled in the background isolate
  /// (`applyNotificationAction`) and are picked up here on next load, since both
  /// paths write the same file.
  void _onNotificationAction(NotificationPayload payload, String? actionId) {
    switch (payload) {
      case DosePayload(:final slotKey):
        switch (actionId) {
          case kActionTaken:
            unawaited(confirmTaken(slotKey));
          case kActionSkip:
            unawaited(skip(slotKey));
          case kActionSnooze:
            unawaited(snooze(slotKey));
          default:
            // Plain tap: surface the dose as an in-app alarm if it is still due.
            _raiseAlarmForKey(slotKey);
        }
      case WaterPayload(:final at):
        switch (actionId) {
          case kActionLogWater:
            unawaited(addWater());
          case kActionDismiss:
            _clearAlarmKind(ReminderKind.water);
          default:
            _onDesktopFire(ReminderFire(kind: ReminderKind.water, at: at));
        }
    }
  }

  void _raiseAlarmForKey(String slotKey) {
    for (final slot in dueNow) {
      if (slot.key == slotKey) {
        _onDesktopFire(ReminderFire(
          kind: ReminderKind.dose,
          slot: slot,
          at: effectiveDueOf(slot),
        ));
        return;
      }
    }
    unawaited(_tray?.showWindow() ?? Future<void>.value());
  }

  // -------------------------------------------------------------------------
  // Timers
  // -------------------------------------------------------------------------

  void _onUiTick() {
    _now = DateTime.now();
    final signature = _computeUiSignature();
    if (signature == _uiSignature) return;
    _uiSignature = signature;
    notifyListeners();
  }

  /// Everything time-dependent the UI can see, so the 1 s tick only rebuilds
  /// when a countdown digit, a due list, an alarm or the pause state changed.
  String _computeUiSignature() {
    final next = nextDose;
    final buffer = StringBuffer()
      ..write(dueNow.map((slot) => slot.key).join(','))
      ..write('|')
      ..write(next?.key ?? '')
      ..write('|');
    if (next != null) {
      final remaining = effectiveDueOf(next).difference(_now);
      // Seconds resolution near the dose, minutes when it is far away.
      buffer.write(remaining.inHours >= 1
          ? '${remaining.inMinutes}m'
          : '${remaining.inSeconds}s');
    }
    buffer
      ..write('|')
      ..write(activeAlarm?.key ?? '')
      ..write('|')
      ..write(isPaused ? settings.pausedUntil?.toIso8601String() : '')
      ..write('|')
      ..write(DoseKey.dayString(_now));
    return buffer.toString();
  }

  Future<void> _onSweep() async {
    await syncFromDisk();
    await _sweepMissed();
  }

  /// Picks up anything the background isolate wrote while the app was running.
  ///
  /// Cheap: it stats the data file and only reads it when the modification time
  /// moved since our own last write. Also worth calling when the app resumes
  /// (P3 can hook it to an app lifecycle listener).
  Future<void> syncFromDisk() async {
    final mtime = await _storage.lastModified();
    if (mtime == null || mtime == _lastKnownMtime) return;
    _lastKnownMtime = mtime;
    final merged = mergeExternalChanges(_data, await _storage.load());
    if (merged == null) return;
    _data = merged;
    // A dose resolved from the notification shade must stop ringing in-app.
    for (final record in _data.records.values) {
      if (record.status.isActed) _clearAlarmFor('dose#${record.key}');
    }
    _uiSignature = _computeUiSignature();
    notifyListeners();
  }

  Future<void> _sweepMissed({bool persist = true}) async {
    final now = DateTime.now();
    final missed = ScheduleEngine.sweepMissed(
      meds,
      _data.records,
      now,
      settings.grace,
    );
    if (missed.isEmpty) return;
    _data = _data.copyWith(records: <String, DoseRecord>{
      ..._data.records,
      for (final record in missed) record.key: record,
    });
    for (final record in missed) {
      _clearAlarmFor('dose#${record.key}');
      await _notifications.cancelSlot(
        record.key,
        nagCount: settings.nagMaxCount,
      );
    }
    if (persist) {
      await _persist();
      notifyListeners();
    }
  }

  // -------------------------------------------------------------------------
  // Persistence
  // -------------------------------------------------------------------------

  /// The one write path: swap state in, persist, reschedule, notify.
  Future<void> _mutate(AppData next) async {
    _data = next;
    await _persist();
    _uiSignature = _computeUiSignature();
    notifyListeners();
  }

  Future<void> _persist() async {
    await _storage.save(_data);
    // Remember our own write so [syncFromDisk] can tell it apart from the
    // background isolate's.
    _lastKnownMtime = await _storage.lastModified();
    await _notifications.rescheduleAll(_data);
  }
}
