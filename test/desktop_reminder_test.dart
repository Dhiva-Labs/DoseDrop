import 'package:dose_drop/models/models.dart';
import 'package:dose_drop/services/desktop_reminder_engine.dart';
import 'package:flutter_test/flutter_test.dart';

const String medId = 'm1';

DateTime at(int hour, int minute, {int day = 27}) =>
    DateTime(2026, 7, day, hour, minute);

AppData buildData({
  List<String> times = const <String>['08:00'],
  Map<String, DoseRecord> records = const <String, DoseRecord>{},
  AppSettings settings = const AppSettings(),
  WaterSettings water = const WaterSettings(enabled: false),
  bool medEnabled = true,
}) =>
    AppData(
      meds: <Medication>[
        Medication(
          id: medId,
          name: 'Metformin',
          dosage: '500 mg',
          times: times,
          enabled: medEnabled,
        ),
      ],
      records: records,
      settings: settings,
      waterSettings: water,
    );

String doseKeyAt(String time, {int day = 27}) =>
    DoseKey.build(medId, DateTime(2026, 7, day), time);

/// Convenience: run the planner and return the fire keys.
List<String> fireKeys(ReminderTick tick) =>
    <String>[for (final fire in tick.fire) fire.dedupeKey];

void main() {
  group('doses', () {
    test('fires once when a dose comes due', () {
      final tick = ReminderPlanner.plan(
        data: buildData(),
        now: at(8, 0),
        seen: <String>{},
      );

      expect(tick.fire, hasLength(1));
      expect(tick.fire.single.kind, ReminderKind.dose);
      expect(tick.fire.single.at, at(8, 0));
      expect(tick.fire.single.nag, 0);
      expect(tick.swallow, isEmpty);
    });

    test('does not fire the same due point twice', () {
      final data = buildData();
      final first = ReminderPlanner.plan(
        data: data,
        now: at(8, 0),
        seen: <String>{},
      );
      final seen = fireKeys(first).toSet();

      final second = ReminderPlanner.plan(
        data: data,
        now: at(8, 2),
        seen: seen,
      );

      expect(second.fire, isEmpty);
      expect(second.swallow, isEmpty);
    });

    test('escalates to the nag points as they arrive', () {
      final data = buildData();
      final seen = <String>{};

      final due = ReminderPlanner.plan(data: data, now: at(8, 0), seen: seen);
      seen.addAll(fireKeys(due));

      // nagIntervalMin defaults to 5, so 08:05 is nag 1.
      final nag1 = ReminderPlanner.plan(data: data, now: at(8, 5), seen: seen);
      expect(nag1.fire, hasLength(1));
      expect(nag1.fire.single.nag, 1);
      expect(nag1.fire.single.at, at(8, 5));
      seen.addAll(fireKeys(nag1));

      final between = ReminderPlanner.plan(
        data: data,
        now: at(8, 7),
        seen: seen,
      );
      expect(between.fire, isEmpty);

      final nag2 = ReminderPlanner.plan(data: data, now: at(8, 10), seen: seen);
      expect(nag2.fire.single.nag, 2);

      seen.addAll(fireKeys(nag2));
      final nag3 = ReminderPlanner.plan(data: data, now: at(8, 15), seen: seen);
      expect(nag3.fire.single.nag, 3);

      // nagMaxCount is 3: nothing more, even later in the grace window.
      seen.addAll(fireKeys(nag3));
      final after = ReminderPlanner.plan(data: data, now: at(8, 40), seen: seen);
      expect(after.fire, isEmpty);
    });

    test('a sleeping app fires only the newest point and swallows the rest', () {
      // Woken at 08:12: due, nag1 and nag2 have all passed.
      final tick = ReminderPlanner.plan(
        data: buildData(),
        now: at(8, 12),
        seen: <String>{},
      );

      expect(tick.fire, hasLength(1));
      expect(tick.fire.single.nag, 2);
      expect(tick.swallow, hasLength(2)); // the due point and nag 1
      expect(tick.swallow, contains('dose#${doseKeyAt('08:00')}'
          '#${at(8, 0).toIso8601String()}'));
    });

    test('nothing fires before the due time', () {
      final tick = ReminderPlanner.plan(
        data: buildData(),
        now: at(7, 59),
        seen: <String>{},
      );

      expect(tick.fire, isEmpty);
      expect(tick.swallow, isEmpty);
    });

    test('nothing fires once the grace window has closed', () {
      // Default grace is 60 min, so at 09:00 the dose is missed, not ringing.
      final tick = ReminderPlanner.plan(
        data: buildData(),
        now: at(9, 0),
        seen: <String>{},
      );

      expect(tick.fire, isEmpty);
    });

    test('resolved and disabled doses never ring', () {
      final taken = ReminderPlanner.plan(
        data: buildData(records: <String, DoseRecord>{
          doseKeyAt('08:00'): DoseRecord(
            key: doseKeyAt('08:00'),
            status: DoseStatus.taken,
            actedAt: at(8, 1),
          ),
        }),
        now: at(8, 5),
        seen: <String>{},
      );
      final disabled = ReminderPlanner.plan(
        data: buildData(medEnabled: false),
        now: at(8, 5),
        seen: <String>{},
      );

      expect(taken.fire, isEmpty);
      expect(disabled.fire, isEmpty);
    });

    test('a snooze moves the whole ladder', () {
      final key = doseKeyAt('08:00');
      final data = buildData(records: <String, DoseRecord>{
        key: DoseRecord(key: key, snoozedUntil: at(8, 30)),
      });

      expect(
        ReminderPlanner.plan(data: data, now: at(8, 20), seen: <String>{}).fire,
        isEmpty,
      );
      final fired =
          ReminderPlanner.plan(data: data, now: at(8, 30), seen: <String>{});
      expect(fired.fire.single.at, at(8, 30));
      expect(fired.fire.single.nag, 0);

      final nag = ReminderPlanner.plan(
        data: data,
        now: at(8, 35),
        seen: fireKeys(fired).toSet(),
      );
      expect(nag.fire.single.nag, 1);
      expect(nag.fire.single.at, at(8, 35));
    });

    test('two doses due at once both ring, each at its own point', () {
      final tick = ReminderPlanner.plan(
        data: buildData(times: const <String>['08:00', '08:10']),
        now: at(8, 10),
        seen: <String>{},
      );

      // The 08:00 dose is on its second nag (08:00 + 2 x 5 min) while the 08:10
      // dose is only just coming due — both alert, tracked separately.
      expect(tick.fire, hasLength(2));
      expect(
        tick.fire.map((f) => (f.slot!.time, f.nag, f.at)).toList(),
        <(String, int, DateTime)>[
          ('08:00', 2, at(8, 10)),
          ('08:10', 0, at(8, 10)),
        ],
      );
      // The earlier points of the 08:00 dose are swallowed, not re-fired.
      expect(tick.swallow, hasLength(2));
    });

    test('nag points beyond nagMaxCount are never produced', () {
      final tick = ReminderPlanner.plan(
        data: buildData(settings: const AppSettings(nagMaxCount: 1)),
        now: at(8, 30),
        seen: <String>{},
      );

      // Only the due point and nag 1 exist; nag 1 is newest so it fires.
      expect(tick.fire.single.nag, 1);
      expect(tick.swallow, hasLength(1));
    });
  });

  group('pause', () {
    test('swallows everything while paused, so no backlog bursts later', () {
      final data = buildData(
        settings: AppSettings(pausedUntil: at(9, 30)),
      );

      final during = ReminderPlanner.plan(
        data: data,
        now: at(8, 12),
        seen: <String>{},
      );

      expect(during.fire, isEmpty);
      expect(during.swallow, hasLength(3)); // due + nag 1 + nag 2

      // After the pause the swallowed points stay silent.
      final after = ReminderPlanner.plan(
        data: buildData(settings: AppSettings(pausedUntil: at(9, 30))),
        now: at(9, 35),
        seen: during.swallow.toSet(),
      );
      expect(after.fire, isEmpty);
    });

    test('a dose that comes due after the pause ends rings normally', () {
      final data = buildData(
        times: const <String>['10:00'],
        settings: AppSettings(pausedUntil: at(9, 30)),
      );

      final tick = ReminderPlanner.plan(
        data: data,
        now: at(10, 0),
        seen: <String>{},
      );

      expect(tick.fire.single.at, at(10, 0));
    });
  });

  group('water', () {
    final water = const WaterSettings();

    test('fires the slot that just passed', () {
      final tick = ReminderPlanner.plan(
        data: buildData(times: const <String>[], water: water),
        now: at(8, 5),
        seen: <String>{},
      );

      expect(tick.fire, hasLength(1));
      expect(tick.fire.single.kind, ReminderKind.water);
      expect(tick.fire.single.at, at(8, 0));
    });

    test('stays quiet once the slot is stale', () {
      final tick = ReminderPlanner.plan(
        data: buildData(times: const <String>[], water: water),
        now: at(8, 30), // more than the 15 min catch-up
        seen: <String>{},
      );

      expect(tick.fire, isEmpty);
      expect(tick.swallow, hasLength(1));
    });

    test('opening the app late does not fire a day of reminders', () {
      final tick = ReminderPlanner.plan(
        data: buildData(times: const <String>[], water: water),
        now: at(12, 2),
        seen: <String>{},
      );

      // 08:00–12:00 have passed; only the 12:00 one alerts.
      expect(tick.fire.single.at, at(12, 0));
      expect(tick.swallow, hasLength(4));
    });

    test('disabled water settings produce nothing at all', () {
      final tick = ReminderPlanner.plan(
        data: buildData(
          times: const <String>[],
          water: const WaterSettings(enabled: false),
        ),
        now: at(12, 2),
        seen: <String>{},
      );

      expect(tick.fire, isEmpty);
      expect(tick.swallow, isEmpty);
    });

    test('does not repeat a slot that already fired', () {
      final data = buildData(times: const <String>[], water: water);
      final first =
          ReminderPlanner.plan(data: data, now: at(8, 1), seen: <String>{});

      final second = ReminderPlanner.plan(
        data: data,
        now: at(8, 3),
        seen: fireKeys(first).toSet(),
      );

      expect(second.fire, isEmpty);
    });

    test('outside active hours nothing is due', () {
      final tick = ReminderPlanner.plan(
        data: buildData(times: const <String>[], water: water),
        now: at(6, 30), // before activeStartMin 08:00
        seen: <String>{},
      );

      expect(tick.fire, isEmpty);
      expect(tick.swallow, isEmpty);
    });
  });

  group('dedupe keys', () {
    test('identify a slot and its exact alerting moment', () {
      final fire = ReminderFire(
        kind: ReminderKind.dose,
        slot: DoseSlot(
          med: const Medication(id: medId, name: 'Metformin'),
          scheduledAt: at(8, 0),
        ),
        at: at(8, 5),
        nag: 1,
      );

      expect(fire.dedupeKey,
          'dose#${doseKeyAt('08:00')}#${at(8, 5).toIso8601String()}');
      expect(
        ReminderFire(kind: ReminderKind.water, at: at(8, 0)).dedupeKey,
        'water#${at(8, 0).toIso8601String()}',
      );
    });
  });
}
