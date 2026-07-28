import '../models/models.dart';

/// How many of a day's scheduled doses have been taken.
///
/// `total` counts every dose scheduled that day (including ones still in the
/// future); `taken` counts those marked [DoseStatus.taken].
typedef Adherence = ({int taken, int total});

/// All scheduling maths for DoseDrop: which doses exist, when they are due,
/// which are ringing right now, which expired, and the history stats.
///
/// **Pure static Dart** — no Flutter, no I/O, no clock of its own: every
/// function takes the state and `now` explicitly, so all of it is unit-testable
/// and reusable from the Android background isolate.
///
/// All `DateTime`s are local wall-clock and timezone-naive; day arithmetic goes
/// through [Days] so DST never shifts a dose to another calendar day.
class ScheduleEngine {
  ScheduleEngine._();

  /// How far ahead [nextDose] searches before giving up.
  static const int nextDoseHorizonDays = 8;

  /// How far back [sweepMissed] looks for unresolved doses.
  static const int missedLookbackDays = 7;

  /// Upper bound for the streak scans (keeps them O(1)-ish on long histories).
  static const int streakLookbackDays = 366;

  /// Days scanned before "today" when hunting for doses that are still due —
  /// covers snoozes and grace windows that crossed midnight.
  static const int _dueLookbackDays = 2;

  // -------------------------------------------------------------------------
  // Slots
  // -------------------------------------------------------------------------

  /// Every dose scheduled on [day], sorted by time (ties: med name, then id).
  ///
  /// Disabled meds are skipped, as are meds whose [Medication.days] does not
  /// contain the day's weekday (`Mon = 1 … Sun = 7`). Malformed and duplicate
  /// `"HH:mm"` entries are ignored, so slot keys are always unique.
  static List<DoseSlot> slotsForDay(List<Medication> meds, DateTime day) {
    final start = Days.startOf(day);
    final slots = <DoseSlot>[];
    for (final med in meds) {
      if (!med.enabled) continue;
      if (!med.days.contains(start.weekday)) continue;
      final seen = <int>{};
      for (final time in med.times) {
        final minutes = HhMm.tryParse(time);
        if (minutes == null || !seen.add(minutes)) continue;
        slots.add(DoseSlot(
          med: med,
          scheduledAt: DateTime(start.year, start.month, start.day,
              minutes ~/ 60, minutes % 60),
        ));
      }
    }
    slots.sort(_bySchedule);
    return slots;
  }

  /// When a slot is actually due: the snooze time wins while the dose is still
  /// pending, otherwise its scheduled time.
  static DateTime effectiveDue(DoseSlot slot, DoseRecord? record) {
    final snoozedUntil = record?.snoozedUntil;
    if (snoozedUntil != null && !record!.status.isActed) return snoozedUntil;
    return slot.scheduledAt;
  }

  /// The next unresolved dose due at or after [now], or `null` if there is none
  /// within [nextDoseHorizonDays].
  ///
  /// Doses already taken/skipped/missed are ignored. A snoozed pending dose
  /// surfaces at its snooze time, which is why the scan also covers yesterday
  /// (a 23:55 dose snoozed by 10 min is due today).
  static DoseSlot? nextDose(
    List<Medication> meds,
    Map<String, DoseRecord> records,
    DateTime now,
  ) {
    DoseSlot? best;
    DateTime? bestDue;
    for (var offset = -1; offset <= nextDoseHorizonDays; offset++) {
      for (final slot in slotsForDay(meds, Days.add(now, offset))) {
        final record = records[slot.key];
        if (record != null && record.status.isActed) continue;
        final due = effectiveDue(slot, record);
        if (due.isBefore(now)) continue;
        if (bestDue == null || due.isBefore(bestDue)) {
          best = slot;
          bestDue = due;
        }
      }
    }
    return best;
  }

  /// Doses that should be alerting right now: `effectiveDue <= now` and
  /// `now < effectiveDue + grace`, still unresolved, oldest first.
  ///
  /// The window is half-open on purpose — a dose exactly at `due + grace` has
  /// expired and belongs to [sweepMissed] instead, never to both.
  static List<DoseSlot> dueNow(
    List<Medication> meds,
    Map<String, DoseRecord> records,
    DateTime now,
    Duration grace,
  ) {
    final found = <({DoseSlot slot, DateTime due})>[];
    final lookback = _dueLookbackDays + grace.inDays.abs();
    for (var offset = -lookback; offset <= 0; offset++) {
      for (final slot in slotsForDay(meds, Days.add(now, offset))) {
        final record = records[slot.key];
        if (record != null && record.status.isActed) continue;
        final due = effectiveDue(slot, record);
        if (due.isAfter(now)) continue; // not due yet
        if (!now.isBefore(due.add(grace))) continue; // grace window expired
        found.add((slot: slot, due: due));
      }
    }
    found.sort((a, b) => a.due.compareTo(b.due));
    return [for (final entry in found) entry.slot];
  }

  /// Records for doses whose grace window closed without an action
  /// (`effectiveDue + grace <= now`), looking back [missedLookbackDays].
  ///
  /// Returns freshly built [DoseStatus.missed] records — [records] is never
  /// mutated. Any existing snooze is preserved and `actedAt` is set to [now]
  /// (the sweep time). The caller persists the result.
  static List<DoseRecord> sweepMissed(
    List<Medication> meds,
    Map<String, DoseRecord> records,
    DateTime now,
    Duration grace,
  ) {
    final missed = <DoseRecord>[];
    for (var offset = -missedLookbackDays; offset <= 0; offset++) {
      for (final slot in slotsForDay(meds, Days.add(now, offset))) {
        final record = records[slot.key];
        if (record != null && record.status.isActed) continue;
        final due = effectiveDue(slot, record);
        if (now.isBefore(due.add(grace))) continue; // still inside grace
        missed.add((record ?? DoseRecord(key: slot.key))
            .copyWith(status: DoseStatus.missed, actedAt: now));
      }
    }
    return missed;
  }

  /// The escalating re-alert times for a dose due at [due]:
  /// `due + i * nagInterval` for `i = 1 … nagMaxCount`.
  ///
  /// Empty when nagging is switched off (count or interval `<= 0`).
  static List<DateTime> nagTimes(DateTime due, AppSettings settings) {
    if (settings.nagMaxCount <= 0 || settings.nagIntervalMin <= 0) {
      return const <DateTime>[];
    }
    return [
      for (var i = 1; i <= settings.nagMaxCount; i++)
        due.add(Duration(minutes: settings.nagIntervalMin * i)),
    ];
  }

  /// Water reminder times on [day]: every [WaterSettings.intervalMin] from
  /// [WaterSettings.activeStartMin] up to and including
  /// [WaterSettings.activeEndMin].
  ///
  /// Empty when water reminders are disabled, when the interval is not positive
  /// or when the active window is inverted. Times never spill past 23:59.
  static List<DateTime> waterSlotsForDay(WaterSettings settings, DateTime day) {
    if (!settings.enabled || settings.intervalMin <= 0) {
      return const <DateTime>[];
    }
    final start = settings.activeStartMin < 0 ? 0 : settings.activeStartMin;
    final end = settings.activeEndMin;
    if (end < start) return const <DateTime>[];
    final startOfDay = Days.startOf(day);
    final slots = <DateTime>[];
    for (var minutes = start;
        minutes <= end && minutes < HhMm.minutesPerDay;
        minutes += settings.intervalMin) {
      slots.add(DateTime(startOfDay.year, startOfDay.month, startOfDay.day,
          minutes ~/ 60, minutes % 60));
    }
    return slots;
  }

  // -------------------------------------------------------------------------
  // Stats
  // -------------------------------------------------------------------------

  /// Taken-vs-scheduled for [day]. `total` is every dose scheduled that day,
  /// so a day still in progress reports the whole day's denominator.
  static Adherence adherenceForDay(
    List<Medication> meds,
    Map<String, DoseRecord> records,
    DateTime day,
  ) {
    var taken = 0;
    var total = 0;
    for (final slot in slotsForDay(meds, day)) {
      total++;
      if (records[slot.key]?.status == DoseStatus.taken) taken++;
    }
    return (taken: taken, total: total);
  }

  /// Total ml logged on [day].
  static int waterMlForDay(List<WaterEntry> entries, DateTime day) {
    var ml = 0;
    for (final entry in entries) {
      if (Days.same(entry.at, day)) ml += entry.ml;
    }
    return ml;
  }

  /// A day is **complete** when it has at least one scheduled dose and every
  /// one of them is [DoseStatus.taken].
  ///
  /// Days with no scheduled dose are *not* complete — for streak purposes they
  /// are neutral (see [currentStreak]), not credited.
  static bool isDayComplete(
    List<Medication> meds,
    Map<String, DoseRecord> records,
    DateTime day,
  ) {
    final adherence = adherenceForDay(meds, records, day);
    return adherence.total > 0 && adherence.taken == adherence.total;
  }

  /// Length of the streak of complete days ending at [today].
  ///
  /// Semantics (shared with [bestStreak]):
  /// * A day **counts** only if it has scheduled doses (`total > 0`) and all of
  ///   them are taken — see [isDayComplete].
  /// * A day with `total == 0` (nothing scheduled: med disabled, weekday not in
  ///   its schedule, med not created yet) is **neutral**: it neither adds to the
  ///   streak nor breaks it, the walk simply steps over it.
  /// * A day with scheduled doses that are not all taken **breaks** the streak.
  /// * [today] is included only when it is *already* fully taken — every dose
  ///   scheduled for today, including ones later in the day. An incomplete
  ///   today does not break anything: the streak then ends at yesterday, so it
  ///   never dips while the day is still in progress.
  ///
  /// The walk stops after [maxLookbackDays] days.
  static int currentStreak(
    List<Medication> meds,
    Map<String, DoseRecord> records,
    DateTime today, {
    int maxLookbackDays = streakLookbackDays,
  }) {
    var streak = 0;
    for (var back = 0; back <= maxLookbackDays; back++) {
      final adherence = adherenceForDay(meds, records, Days.add(today, -back));
      if (adherence.total == 0) continue; // neutral day
      if (adherence.taken == adherence.total) {
        streak++;
        continue;
      }
      if (back == 0) continue; // today still in progress
      break;
    }
    return streak;
  }

  /// Longest run of complete days in the recorded history up to [today], using
  /// exactly the same day semantics as [currentStreak] (neutral days are
  /// stepped over, incomplete days reset the run).
  ///
  /// The scan starts at the oldest day present in [records] (capped at
  /// [maxLookbackDays]), since no day before that can be complete. Always
  /// `>= currentStreak`.
  static int bestStreak(
    List<Medication> meds,
    Map<String, DoseRecord> records,
    DateTime today, {
    int maxLookbackDays = streakLookbackDays,
  }) {
    var best = 0;
    var run = 0;
    final depth = _historyDepthDays(records, today, maxLookbackDays);
    for (var offset = -depth; offset <= 0; offset++) {
      final adherence = adherenceForDay(meds, records, Days.add(today, offset));
      if (adherence.total == 0) continue; // neutral day
      if (adherence.taken == adherence.total) {
        run++;
        if (run > best) best = run;
      } else {
        run = 0;
      }
    }
    return best;
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  /// Days between [today] and the oldest day referenced by [records], capped.
  static int _historyDepthDays(
    Map<String, DoseRecord> records,
    DateTime today,
    int maxLookbackDays,
  ) {
    var depth = 0;
    for (final key in records.keys) {
      final parts = DoseKey.tryParse(key);
      if (parts == null) continue;
      final days = Days.diffInDays(parts.day, today);
      if (days > depth) depth = days;
    }
    return depth > maxLookbackDays ? maxLookbackDays : depth;
  }

  static int _bySchedule(DoseSlot a, DoseSlot b) {
    final byTime = a.scheduledAt.compareTo(b.scheduledAt);
    if (byTime != 0) return byTime;
    final byName =
        a.med.name.toLowerCase().compareTo(b.med.name.toLowerCase());
    return byName != 0 ? byName : a.med.id.compareTo(b.med.id);
  }
}
