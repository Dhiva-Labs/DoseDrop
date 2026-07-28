import 'package:dose_drop/models/models.dart';
import 'package:dose_drop/services/schedule_engine.dart';
import 'package:flutter_test/flutter_test.dart';

// Fixture calendar (asserted in the first test):
//   Mon 2026-07-20 … Sun 2026-07-26, Mon 2026-07-27 … Sun 2026-08-02.
DateTime day(int monthDay, {int month = 7, int year = 2026}) =>
    DateTime(year, month, monthDay);

DateTime at(int monthDay, int hour, int minute, {int month = 7}) =>
    DateTime(2026, month, monthDay, hour, minute);

Medication buildMed({
  String id = 'm1',
  String name = 'Metformin',
  List<String> times = const <String>['08:00'],
  Set<int> days = Medication.everyDay,
  bool enabled = true,
}) =>
    Medication(
      id: id,
      name: name,
      dosage: '500 mg',
      times: times,
      days: days,
      enabled: enabled,
    );

Map<String, DoseRecord> records(Iterable<DoseRecord> list) =>
    <String, DoseRecord>{for (final record in list) record.key: record};

DoseRecord recordFor(
  Medication med,
  DateTime slotDay,
  String time, {
  DoseStatus status = DoseStatus.pending,
  DateTime? actedAt,
  DateTime? snoozedUntil,
}) {
  return DoseRecord(
    key: DoseKey.build(med.id, slotDay, time),
    status: status,
    actedAt: actedAt,
    snoozedUntil: snoozedUntil,
  );
}

/// One `taken` record per listed day, for a single-time-per-day med.
Map<String, DoseRecord> takenOn(
  Medication med,
  List<DateTime> days, {
  String time = '08:00',
}) =>
    records([
      for (final d in days)
        recordFor(med, d, time,
            status: DoseStatus.taken,
            actedAt: DateTime(d.year, d.month, d.day, 8, 3)),
    ]);

const Duration hourGrace = Duration(minutes: 60);

void main() {
  test('fixture calendar has the expected weekdays', () {
    expect(day(20).weekday, DateTime.monday);
    expect(day(24).weekday, DateTime.friday);
    expect(day(25).weekday, DateTime.saturday);
    expect(day(26).weekday, DateTime.sunday);
    expect(day(27).weekday, DateTime.monday);
    expect(day(28).weekday, DateTime.tuesday);
  });

  group('slotsForDay', () {
    test('expands every time of every enabled med, sorted by time', () {
      final morning = buildMed(
        id: 'a',
        name: 'Aspirin',
        times: const <String>['20:00', '08:00'],
      );
      final vitamin = buildMed(id: 'b', name: 'Vitamin D', times: const <String>['12:30']);

      final slots = ScheduleEngine.slotsForDay([morning, vitamin], day(27));

      expect(slots.map((s) => s.time).toList(), ['08:00', '12:30', '20:00']);
      expect(slots.map((s) => s.med.id).toList(), ['a', 'b', 'a']);
      expect(slots.first.scheduledAt, at(27, 8, 0));
      expect(slots.first.key, 'a|2026-07-27|08:00');
      expect(slots.first.day, day(27));
    });

    test('ties on the same time are ordered by med name then id', () {
      final zinc = buildMed(id: 'z', name: 'Zinc');
      final iron = buildMed(id: 'i', name: 'Iron');

      final slots = ScheduleEngine.slotsForDay([zinc, iron], day(27));

      expect(slots.map((s) => s.med.id).toList(), ['i', 'z']);
    });

    test('excludes disabled meds', () {
      final med = buildMed(enabled: false);

      expect(ScheduleEngine.slotsForDay([med], day(27)), isEmpty);
    });

    test('recurrence respects days-of-week across a whole week', () {
      final weekdaysOnly = buildMed(days: const <int>{1, 2, 3, 4, 5});
      final sundayOnly = buildMed(id: 'm2', days: const <int>{7});

      final counts = <int, int>{
        for (var d = 20; d <= 26; d++)
          d: ScheduleEngine.slotsForDay([weekdaysOnly, sundayOnly], day(d)).length,
      };

      expect(counts, {20: 1, 21: 1, 22: 1, 23: 1, 24: 1, 25: 0, 26: 1});
      expect(
        ScheduleEngine.slotsForDay([sundayOnly], day(26)).single.med.id,
        'm2',
      );
    });

    test('ignores malformed and duplicate times so slot keys stay unique', () {
      final med = buildMed(
        times: const <String>['08:00', '08:00', '', '25:00', '12:61', 'noon', '09:30'],
      );

      final slots = ScheduleEngine.slotsForDay([med], day(27));

      expect(slots.map((s) => s.time).toList(), ['08:00', '09:30']);
      expect(slots.map((s) => s.key).toSet().length, 2);
    });

    test('a med with no schedulable time produces nothing', () {
      expect(
        ScheduleEngine.slotsForDay([buildMed(times: const <String>[])], day(27)),
        isEmpty,
      );
    });
  });

  group('effectiveDue', () {
    final med = buildMed();
    final slot = DoseSlot(med: med, scheduledAt: at(27, 8, 0));

    test('falls back to the scheduled time without a record', () {
      expect(ScheduleEngine.effectiveDue(slot, null), at(27, 8, 0));
    });

    test('a pending record without a snooze keeps the scheduled time', () {
      final record = recordFor(med, day(27), '08:00');

      expect(ScheduleEngine.effectiveDue(slot, record), at(27, 8, 0));
    });

    test('a snooze shifts the due time while the dose is pending', () {
      final record =
          recordFor(med, day(27), '08:00', snoozedUntil: at(27, 8, 10));

      expect(ScheduleEngine.effectiveDue(slot, record), at(27, 8, 10));
    });

    test('a snooze on an acted record is ignored', () {
      final record = recordFor(
        med,
        day(27),
        '08:00',
        status: DoseStatus.taken,
        snoozedUntil: at(27, 8, 10),
      );

      expect(ScheduleEngine.effectiveDue(slot, record), at(27, 8, 0));
    });
  });

  group('nextDose', () {
    final med = buildMed(times: const <String>['08:00', '20:00']);

    test('returns the next slot later the same day', () {
      final next = ScheduleEngine.nextDose([med], const {}, at(27, 9, 0));

      expect(next?.scheduledAt, at(27, 20, 0));
    });

    test('includes a dose that is due exactly now', () {
      final next = ScheduleEngine.nextDose([med], const {}, at(27, 8, 0));

      expect(next?.scheduledAt, at(27, 8, 0));
    });

    test('crosses midnight once the day is done', () {
      final next = ScheduleEngine.nextDose([med], const {}, at(27, 23, 30));

      expect(next?.scheduledAt, at(28, 8, 0));
    });

    test('wraps to next week for a single-weekday med', () {
      final mondayOnly = buildMed(days: const <int>{1}, times: const <String>['08:00']);

      final next = ScheduleEngine.nextDose([mondayOnly], const {}, at(28, 9, 0));

      expect(next?.scheduledAt, DateTime(2026, 8, 3, 8, 0));
      expect(DateTime(2026, 8, 3).weekday, DateTime.monday);
    });

    test('skips doses that were already acted on', () {
      final taken = records([
        recordFor(med, day(27), '20:00',
            status: DoseStatus.taken, actedAt: at(27, 19, 0)),
      ]);

      final next = ScheduleEngine.nextDose([med], taken, at(27, 9, 0));

      expect(next?.scheduledAt, at(28, 8, 0));
    });

    test('a snoozed pending dose surfaces at its snooze time', () {
      final snoozed = records([
        recordFor(med, day(27), '08:00', snoozedUntil: at(27, 8, 10)),
      ]);

      final next = ScheduleEngine.nextDose([med], snoozed, at(27, 8, 1));

      expect(next?.scheduledAt, at(27, 8, 0));
      expect(ScheduleEngine.effectiveDue(next!, snoozed[next.key]),
          at(27, 8, 10));
    });

    test('a snooze past midnight still surfaces the previous day\'s dose', () {
      final lateMed = buildMed(times: const <String>['23:55']);
      final snoozed = records([
        recordFor(lateMed, day(27), '23:55', snoozedUntil: at(28, 0, 5)),
      ]);

      final next = ScheduleEngine.nextDose([lateMed], snoozed, at(28, 0, 1));

      expect(next?.scheduledAt, at(27, 23, 55));
      expect(next?.key, 'm1|2026-07-27|23:55');
    });

    test('a later dose can outrank a snoozed one', () {
      final twice = buildMed(times: const <String>['08:00', '09:00']);
      final snoozed = records([
        recordFor(twice, day(27), '08:00', snoozedUntil: at(27, 9, 30)),
      ]);

      final next = ScheduleEngine.nextDose([twice], snoozed, at(27, 8, 30));

      expect(next?.scheduledAt, at(27, 9, 0));
    });

    test('returns null when nothing is scheduled', () {
      expect(ScheduleEngine.nextDose(const [], const {}, at(27, 9, 0)), isNull);
      expect(
        ScheduleEngine.nextDose(
            [buildMed(enabled: false)], const {}, at(27, 9, 0)),
        isNull,
      );
    });
  });

  group('dueNow', () {
    final med = buildMed(times: const <String>['08:00', '09:00']);

    test('a dose exactly at its due time is due now', () {
      final due = ScheduleEngine.dueNow([med], const {}, at(27, 8, 0), hourGrace);

      expect(due.map((s) => s.time).toList(), ['08:00']);
    });

    test('one minute before the grace edge it is still due now', () {
      final due = ScheduleEngine.dueNow([med], const {}, at(27, 8, 59), hourGrace);

      expect(due.map((s) => s.time).toList(), ['08:00']);
    });

    test('exactly at the grace edge it is no longer due now', () {
      final due = ScheduleEngine.dueNow([med], const {}, at(27, 9, 0), hourGrace);

      // 08:00 expired at 09:00 sharp; only the 09:00 dose is ringing.
      expect(due.map((s) => s.time).toList(), ['09:00']);
    });

    test('a dose in the future is not due yet', () {
      expect(ScheduleEngine.dueNow([med], const {}, at(27, 7, 59), hourGrace),
          isEmpty);
    });

    test('overlapping doses come back oldest first', () {
      final other = buildMed(id: 'm2', name: 'Aspirin', times: const <String>['08:30']);

      final due =
          ScheduleEngine.dueNow([med, other], const {}, at(27, 9, 0), hourGrace);

      expect(due.map((s) => s.time).toList(), ['08:30', '09:00']);
    });

    test('acted doses are excluded', () {
      final acted = records([
        recordFor(med, day(27), '08:00',
            status: DoseStatus.skipped, actedAt: at(27, 8, 1)),
        recordFor(med, day(27), '09:00',
            status: DoseStatus.taken, actedAt: at(27, 9, 1)),
      ]);

      expect(ScheduleEngine.dueNow([med], acted, at(27, 9, 5), hourGrace),
          isEmpty);
    });

    test('a snooze pushes the whole window later', () {
      final snoozed = records([
        recordFor(med, day(27), '08:00', snoozedUntil: at(27, 8, 10)),
      ]);

      expect(
        ScheduleEngine.dueNow([med], snoozed, at(27, 8, 5), hourGrace)
            .map((s) => s.time),
        isEmpty,
      );
      expect(
        ScheduleEngine.dueNow([med], snoozed, at(27, 8, 10), hourGrace)
            .map((s) => s.time)
            .toList(),
        ['08:00'],
      );
      // 08:10 + 60 min grace: still ringing at 09:09, expired at 09:10.
      expect(
        ScheduleEngine.dueNow([med], snoozed, at(27, 9, 9), hourGrace)
            .map((s) => s.time)
            .toList(),
        ['08:00', '09:00'],
      );
      expect(
        ScheduleEngine.dueNow([med], snoozed, at(27, 9, 10), hourGrace)
            .map((s) => s.time)
            .toList(),
        ['09:00'],
      );
    });

    test('a dose snoozed across midnight is found the next day', () {
      final lateMed = buildMed(times: const <String>['23:55']);
      final snoozed = records([
        recordFor(lateMed, day(27), '23:55', snoozedUntil: at(28, 0, 5)),
      ]);

      final due =
          ScheduleEngine.dueNow([lateMed], snoozed, at(28, 0, 6), hourGrace);

      expect(due.single.key, 'm1|2026-07-27|23:55');
    });

    test('a long grace window still finds yesterday\'s dose', () {
      final due = ScheduleEngine.dueNow(
        [med],
        const {},
        at(28, 7, 0),
        const Duration(days: 1),
      );

      expect(due.map((s) => s.key).toList(), [
        'm1|2026-07-27|08:00',
        'm1|2026-07-27|09:00',
      ]);
    });
  });

  group('sweepMissed', () {
    // Scheduled every day, so the 7-day lookback also sweeps older days:
    // assertions target the key under test.
    final med = buildMed(times: const <String>['08:00']);
    const todayKey = 'm1|2026-07-27|08:00';

    DoseRecord? sweptFor(List<DoseRecord> missed, String key) {
      for (final record in missed) {
        if (record.key == key) return record;
      }
      return null;
    }

    test('marks a dose missed exactly at due + grace', () {
      final missed =
          ScheduleEngine.sweepMissed([med], const {}, at(27, 9, 0), hourGrace);

      final swept = sweptFor(missed, todayKey);
      expect(swept, isNotNull);
      expect(swept!.status, DoseStatus.missed);
      expect(swept.actedAt, at(27, 9, 0));
      expect(swept.snoozedUntil, isNull);
    });

    test('one minute before the grace edge nothing is missed', () {
      final missed =
          ScheduleEngine.sweepMissed([med], const {}, at(27, 8, 59), hourGrace);

      expect(sweptFor(missed, todayKey), isNull);
    });

    test('dueNow and sweepMissed never overlap at the boundary', () {
      final boundary = at(27, 9, 0);

      final due = ScheduleEngine.dueNow([med], const {}, boundary, hourGrace);
      final missed =
          ScheduleEngine.sweepMissed([med], const {}, boundary, hourGrace);

      expect(due, isEmpty);
      expect(sweptFor(missed, todayKey), isNotNull);

      // One minute earlier the dose is ringing and not yet missed.
      final ringing = at(27, 8, 59);
      expect(
        ScheduleEngine.dueNow([med], const {}, ringing, hourGrace).single.key,
        todayKey,
      );
      expect(
        sweptFor(
          ScheduleEngine.sweepMissed([med], const {}, ringing, hourGrace),
          todayKey,
        ),
        isNull,
      );
    });

    test('a snooze delays the sweep and is preserved on the record', () {
      final snoozed = records([
        recordFor(med, day(27), '08:00', snoozedUntil: at(27, 8, 30)),
      ]);

      expect(
        sweptFor(
          ScheduleEngine.sweepMissed([med], snoozed, at(27, 9, 29), hourGrace),
          todayKey,
        ),
        isNull,
      );

      final swept = sweptFor(
        ScheduleEngine.sweepMissed([med], snoozed, at(27, 9, 30), hourGrace),
        todayKey,
      );

      expect(swept, isNotNull);
      expect(swept!.status, DoseStatus.missed);
      expect(swept.snoozedUntil, at(27, 8, 30));
      expect(swept.actedAt, at(27, 9, 30));
    });

    test('already acted doses are left alone', () {
      final acted = records([
        recordFor(med, day(27), '08:00',
            status: DoseStatus.taken, actedAt: at(27, 8, 5)),
      ]);

      final missed =
          ScheduleEngine.sweepMissed([med], acted, at(28, 12, 0), hourGrace);

      expect(sweptFor(missed, todayKey), isNull);
      expect(sweptFor(missed, 'm1|2026-07-28|08:00'), isNotNull);
    });

    test('does not mutate the records it was given', () {
      final input = records([
        recordFor(med, day(26), '08:00', snoozedUntil: at(26, 8, 10)),
      ]);
      final before = input.length;
      final beforeStatus = input.values.single.status;

      final missed =
          ScheduleEngine.sweepMissed([med], input, at(27, 12, 0), hourGrace);

      expect(missed, isNotEmpty);
      expect(input.length, before);
      expect(input.values.single.status, beforeStatus);
      expect(input.values.single.actedAt, isNull);
    });

    test('looks back exactly seven days', () {
      final now = at(27, 12, 0);

      final missed = ScheduleEngine.sweepMissed([med], const {}, now, hourGrace);

      // 2026-07-20 (7 days back) through 2026-07-27, oldest first.
      expect(missed.first.key, 'm1|2026-07-20|08:00');
      expect(missed.last.key, 'm1|2026-07-27|08:00');
      expect(missed, hasLength(8));
      expect(
        missed.any((r) => r.key == 'm1|2026-07-19|08:00'),
        isFalse,
      );
    });
  });

  group('nagTimes', () {
    test('produces one re-alert per nag, spaced by the interval', () {
      const settings = AppSettings();

      final times = ScheduleEngine.nagTimes(at(27, 8, 0), settings);

      expect(times, [at(27, 8, 5), at(27, 8, 10), at(27, 8, 15)]);
    });

    test('honours custom interval and count', () {
      const settings = AppSettings(nagIntervalMin: 15, nagMaxCount: 2);

      expect(ScheduleEngine.nagTimes(at(27, 22, 0), settings),
          [at(27, 22, 15), at(27, 22, 30)]);
    });

    test('is empty when nagging is switched off', () {
      expect(
        ScheduleEngine.nagTimes(at(27, 8, 0), const AppSettings(nagMaxCount: 0)),
        isEmpty,
      );
      expect(
        ScheduleEngine.nagTimes(
            at(27, 8, 0), const AppSettings(nagIntervalMin: 0)),
        isEmpty,
      );
    });
  });

  group('waterSlotsForDay', () {
    test('steps through the active window hourly by default', () {
      const settings = WaterSettings();

      final slots = ScheduleEngine.waterSlotsForDay(settings, day(27));

      expect(slots.first, at(27, 8, 0));
      expect(slots.last, at(27, 22, 0)); // activeEndMin 1320 is inclusive
      expect(slots, hasLength(15));
    });

    test('stops before an end that is not on an interval boundary', () {
      const settings = WaterSettings(
        activeStartMin: 480,
        activeEndMin: 500,
        intervalMin: 15,
      );

      expect(ScheduleEngine.waterSlotsForDay(settings, day(27)),
          [at(27, 8, 0), at(27, 8, 15)]);
    });

    test('never spills past midnight', () {
      const settings = WaterSettings(
        activeStartMin: 1380,
        activeEndMin: 2000,
        intervalMin: 30,
      );

      expect(ScheduleEngine.waterSlotsForDay(settings, day(27)),
          [at(27, 23, 0), at(27, 23, 30)]);
    });

    test('is empty when disabled, badly configured or inverted', () {
      expect(
        ScheduleEngine.waterSlotsForDay(
            const WaterSettings(enabled: false), day(27)),
        isEmpty,
      );
      expect(
        ScheduleEngine.waterSlotsForDay(
            const WaterSettings(intervalMin: 0), day(27)),
        isEmpty,
      );
      expect(
        ScheduleEngine.waterSlotsForDay(
          const WaterSettings(activeStartMin: 1320, activeEndMin: 480),
          day(27),
        ),
        isEmpty,
      );
    });
  });

  group('adherenceForDay', () {
    test('counts every scheduled slot, taken only when marked taken', () {
      final med = buildMed(times: const <String>['08:00', '14:00', '20:00']);
      final state = records([
        recordFor(med, day(27), '08:00',
            status: DoseStatus.taken, actedAt: at(27, 8, 2)),
        recordFor(med, day(27), '14:00',
            status: DoseStatus.skipped, actedAt: at(27, 14, 2)),
      ]);

      expect(ScheduleEngine.adherenceForDay([med], state, day(27)),
          (taken: 1, total: 3));
    });

    test('a day with nothing scheduled is zero of zero', () {
      final med = buildMed(days: const <int>{1});

      expect(ScheduleEngine.adherenceForDay([med], const {}, day(28)),
          (taken: 0, total: 0));
      expect(ScheduleEngine.isDayComplete([med], const {}, day(28)), isFalse);
    });

    test('missed doses do not count as taken', () {
      final med = buildMed();
      final state = records([
        recordFor(med, day(27), '08:00',
            status: DoseStatus.missed, actedAt: at(27, 9, 0)),
      ]);

      expect(ScheduleEngine.adherenceForDay([med], state, day(27)),
          (taken: 0, total: 1));
    });
  });

  group('waterMlForDay', () {
    test('sums only the entries logged that day', () {
      final entries = <WaterEntry>[
        WaterEntry(at: at(27, 8, 0), ml: 250),
        WaterEntry(at: at(27, 23, 59), ml: 500),
        WaterEntry(at: at(28, 0, 1), ml: 250),
      ];

      expect(ScheduleEngine.waterMlForDay(entries, day(27)), 750);
      expect(ScheduleEngine.waterMlForDay(entries, day(28)), 250);
      expect(ScheduleEngine.waterMlForDay(entries, day(29)), 0);
      expect(ScheduleEngine.waterMlForDay(const [], day(27)), 0);
    });
  });

  group('streaks', () {
    test('a fully taken today is part of the current streak', () {
      final med = buildMed();
      final state = takenOn(med, [day(27), day(26), day(25)]);

      expect(ScheduleEngine.currentStreak([med], state, day(27)), 3);
    });

    test('an incomplete today ends the streak at yesterday', () {
      final med = buildMed(times: const <String>['08:00', '20:00']);
      final state = records([
        // Today: morning taken, evening still pending.
        recordFor(med, day(27), '08:00',
            status: DoseStatus.taken, actedAt: at(27, 8, 2)),
        // Yesterday: both taken.
        recordFor(med, day(26), '08:00',
            status: DoseStatus.taken, actedAt: at(26, 8, 2)),
        recordFor(med, day(26), '20:00',
            status: DoseStatus.taken, actedAt: at(26, 20, 2)),
      ]);

      expect(ScheduleEngine.currentStreak([med], state, day(27)), 1);
    });

    test('days with nothing scheduled are neutral', () {
      final weekdaysOnly = buildMed(days: const <int>{1, 2, 3, 4, 5});
      final state = takenOn(weekdaysOnly, [
        day(27), // Mon
        day(24), // Fri
        day(23),
        day(22),
        day(21),
        day(20), // Mon
      ]);

      // Sat 25 + Sun 26 are neutral and stepped over; Fri 17 has no record and
      // breaks the walk.
      expect(ScheduleEngine.currentStreak([weekdaysOnly], state, day(27)), 6);
    });

    test('a day with an untaken dose breaks the streak', () {
      final med = buildMed();
      final state = takenOn(med, [day(27), day(26), day(24), day(23)]);

      expect(ScheduleEngine.currentStreak([med], state, day(27)), 2);
    });

    test('an empty history has no streak', () {
      final med = buildMed();

      expect(ScheduleEngine.currentStreak([med], const {}, day(27)), 0);
      expect(ScheduleEngine.bestStreak([med], const {}, day(27)), 0);
      expect(ScheduleEngine.currentStreak(const [], const {}, day(27)), 0);
      expect(ScheduleEngine.bestStreak(const [], const {}, day(27)), 0);
    });

    test('best streak remembers the longest historical run', () {
      final med = buildMed();
      final state = takenOn(med, [
        day(28), day(27), // current run of 2, today (29) still open
        day(23), day(22), day(21), day(20), // historical run of 4
      ]);

      expect(ScheduleEngine.currentStreak([med], state, day(29)), 2);
      expect(ScheduleEngine.bestStreak([med], state, day(29)), 4);
    });

    test('best streak is never below the current streak', () {
      final med = buildMed();
      final state = takenOn(med, [day(27), day(26), day(25)]);

      final current = ScheduleEngine.currentStreak([med], state, day(27));

      expect(ScheduleEngine.bestStreak([med], state, day(27)), current);
    });

    test('a skipped dose is not a taken dose', () {
      final med = buildMed();
      final state = <String, DoseRecord>{
        ...takenOn(med, [day(27), day(26)]),
        ...records([
          recordFor(med, day(25), '08:00',
              status: DoseStatus.skipped, actedAt: at(25, 8, 30)),
        ]),
      };

      expect(ScheduleEngine.currentStreak([med], state, day(27)), 2);
      expect(ScheduleEngine.bestStreak([med], state, day(27)), 2);
    });
  });

  group('dose keys', () {
    test('slot keys follow "<medId>|<yyyy-MM-dd>|<HH:mm>"', () {
      final med = buildMed(id: 'abc', times: const <String>['07:05']);

      final slot = ScheduleEngine.slotsForDay([med], day(9, month: 1)).single;

      expect(slot.key, 'abc|2026-01-09|07:05');
    });

    test('keys round-trip through DoseKey.tryParse', () {
      const key = 'abc|2026-01-09|07:05';

      final parts = DoseKey.tryParse(key);

      expect(parts?.medId, 'abc');
      expect(parts?.day, DateTime(2026, 1, 9));
      expect(parts?.time, '07:05');
      expect(DoseKey.scheduledAtOf(key), DateTime(2026, 1, 9, 7, 5));
      expect(DoseKey.tryParse('nope'), isNull);
      expect(DoseKey.tryParse('abc|2026-01-09|99:99'), isNull);
    });
  });
}
