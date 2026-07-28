import 'package:dose_drop/models/models.dart';
import 'package:dose_drop/services/app_state.dart';
import 'package:dose_drop/services/notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

const String medId = 'med-1';
const String doseKey = 'med-1|2026-07-27|08:00';

DateTime at(int day, int hour, int minute) =>
    DateTime(2026, 7, day, hour, minute);

NotificationResponse response(String? payload, String? actionId) =>
    NotificationResponse(
      notificationResponseType: NotificationResponseType.selectedNotificationAction,
      payload: payload,
      actionId: actionId,
    );

AppData sampleData({Map<String, DoseRecord> records = const {}}) => AppData(
      meds: const <Medication>[
        Medication(
          id: medId,
          name: 'Metformin',
          dosage: '500 mg',
          times: <String>['08:00'],
        ),
      ],
      records: records,
    );

void main() {
  group('fnv1a', () {
    test('matches the published FNV-1a 32-bit test vectors', () {
      expect(NotificationIds.fnv1a(''), 0x811C9DC5);
      expect(NotificationIds.fnv1a('a'), 0xE40C292C);
      expect(NotificationIds.fnv1a('foobar'), 0xBF9CF968);
    });

    test('is stable and case sensitive', () {
      expect(NotificationIds.fnv1a(doseKey), NotificationIds.fnv1a(doseKey));
      expect(
        NotificationIds.fnv1a(doseKey),
        isNot(NotificationIds.fnv1a(doseKey.toUpperCase())),
      );
    });

    test('handles non-ASCII payloads as UTF-8 bytes', () {
      expect(NotificationIds.fnv1a('café'), isA<int>());
      expect(NotificationIds.fnv1a('café'), isNot(NotificationIds.fnv1a('cafe')));
    });
  });

  group('notification ids', () {
    test('dose ids stay inside the low 30-bit range', () {
      final id = NotificationIds.forDose(doseKey);

      expect(id, greaterThanOrEqualTo(0));
      expect(id, lessThanOrEqualTo(NotificationIds.mask30));
    });

    test('nag ids are the dose id plus the nag number', () {
      final base = NotificationIds.forDose(doseKey);

      expect(NotificationIds.nagForDose(doseKey, 1), base + 1);
      expect(NotificationIds.nagForDose(doseKey, 3), base + 3);
    });

    test('water ids live in the reserved high range', () {
      final id = NotificationIds.forWater(at(27, 8, 0));

      expect(id, greaterThanOrEqualTo(NotificationIds.waterBase));
      expect(id, lessThan(NotificationIds.test));
      // Never overlaps a dose id, whatever the hash.
      expect(id, greaterThan(NotificationIds.mask30));
    });

    test('the test notification owns the top id', () {
      expect(NotificationIds.test, 0x7FFFFFFF);
    });

    test('distinct slots get distinct ids (no collisions over a year)', () {
      final ids = <int>{};
      var slots = 0;
      for (var day = 1; day <= 28; day++) {
        for (var month = 1; month <= 12; month++) {
          for (final time in <String>['08:00', '14:30', '20:00']) {
            final key = DoseKey.build(medId, DateTime(2026, month, day), time);
            ids.add(NotificationIds.forDose(key));
            slots++;
          }
        }
      }
      expect(ids, hasLength(slots));
    });

    test('ids are stable across calls, which is what cross-isolate cancel needs',
        () {
      final first = NotificationIds.forDose(doseKey);
      final second = NotificationIds.forDose(doseKey);
      final water = NotificationIds.forWater(at(27, 9, 0));

      expect(first, second);
      expect(NotificationIds.forWater(at(27, 9, 0)), water);
    });
  });

  group('payloads', () {
    test('a dose payload is the dose key verbatim', () {
      const payload = DosePayload(doseKey);

      expect(payload.encode(), doseKey);
      expect(payload.notificationId, NotificationIds.forDose(doseKey));
    });

    test('a water payload is water|<date>|<time>', () {
      final payload = WaterPayload(at(27, 8, 0));

      expect(payload.encode(), 'water|2026-07-27|08:00');
    });

    test('round-trips both kinds', () {
      final dose = NotificationPayload.tryParse(doseKey);
      final water = NotificationPayload.tryParse('water|2026-07-27|14:30');

      expect(dose, isA<DosePayload>());
      expect((dose! as DosePayload).slotKey, doseKey);
      expect(water, isA<WaterPayload>());
      expect((water! as WaterPayload).at, at(27, 14, 30));
      expect(water.encode(), 'water|2026-07-27|14:30');
    });

    test('rejects rubbish instead of guessing', () {
      expect(NotificationPayload.tryParse(null), isNull);
      expect(NotificationPayload.tryParse(''), isNull);
      expect(NotificationPayload.tryParse('garbage'), isNull);
      expect(NotificationPayload.tryParse('med-1|nope|08:00'), isNull);
      expect(NotificationPayload.tryParse('med-1|2026-07-27|99:99'), isNull);
      expect(NotificationPayload.tryParse('water|nope|08:00'), isNull);
      expect(NotificationPayload.tryParse('water|2026-07-27'), isNull);
    });
  });

  group('applyActionToData', () {
    final now = at(27, 8, 3);

    test('taken records the dose as taken', () {
      final result = applyActionToData(
        sampleData(),
        const DosePayload(doseKey),
        kActionTaken,
        now,
      );

      final record = result!.data.records[doseKey]!;
      expect(record.status, DoseStatus.taken);
      expect(record.actedAt, now);
      expect(result.snoozedUntil, isNull);
    });

    test('skip records the dose as skipped', () {
      final result = applyActionToData(
        sampleData(),
        const DosePayload(doseKey),
        kActionSkip,
        now,
      );

      expect(result!.data.records[doseKey]!.status, DoseStatus.skipped);
    });

    test('snooze keeps it pending and reports the new due time', () {
      final result = applyActionToData(
        sampleData(),
        const DosePayload(doseKey),
        kActionSnooze,
        now,
      );

      final record = result!.data.records[doseKey]!;
      expect(record.status, DoseStatus.pending);
      expect(record.snoozedUntil,
          now.add(const Duration(minutes: AppSettings.snoozeMinutes)));
      expect(result.snoozedUntil, record.snoozedUntil);
    });

    test('an already resolved dose is left alone', () {
      final data = sampleData(records: <String, DoseRecord>{
        doseKey: DoseRecord(
          key: doseKey,
          status: DoseStatus.taken,
          actedAt: at(27, 8, 1),
        ),
      });

      expect(
        applyActionToData(data, const DosePayload(doseKey), kActionSkip, now),
        isNull,
      );
    });

    test('a snoozed dose can still be taken', () {
      final data = sampleData(records: <String, DoseRecord>{
        doseKey: DoseRecord(key: doseKey, snoozedUntil: at(27, 8, 10)),
      });

      final result = applyActionToData(
        data,
        const DosePayload(doseKey),
        kActionTaken,
        now,
      );

      expect(result!.data.records[doseKey]!.status, DoseStatus.taken);
      expect(result.data.records[doseKey]!.snoozedUntil, isNull);
    });

    test('log_water appends one cup at the action time', () {
      final result = applyActionToData(
        sampleData(),
        WaterPayload(at(27, 9, 0)),
        kActionLogWater,
        now,
      );

      expect(result!.data.water, hasLength(1));
      expect(result.data.water.single.ml, const WaterSettings().cupMl);
      expect(result.data.water.single.at, now);
    });

    test('unknown and dismiss actions change nothing', () {
      expect(
        applyActionToData(
            sampleData(), const DosePayload(doseKey), 'levitate', now),
        isNull,
      );
      expect(
        applyActionToData(
            sampleData(), WaterPayload(at(27, 9, 0)), kActionDismiss, now),
        isNull,
      );
      expect(
        applyActionToData(
            sampleData(), WaterPayload(at(27, 9, 0)), kActionTaken, now),
        isNull,
      );
    });

    test('does not mutate the data it was given', () {
      final data = sampleData();

      applyActionToData(data, const DosePayload(doseKey), kActionTaken, now);

      expect(data.records, isEmpty);
      expect(data.water, isEmpty);
    });
  });

  group('background action plumbing', () {
    test('ignores responses without a usable payload', () async {
      // Nothing to resolve, so it must return without touching storage or
      // needing a plugin — proves a stray notification cannot crash the isolate.
      await applyNotificationAction(response(null, kActionTaken));
      await applyNotificationAction(response('garbage', kActionTaken));
      await applyNotificationAction(response(doseKey, null));
      await applyNotificationAction(response(doseKey, kActionDismiss));
    });

    test('the Android data-dir fallback is inert off Android', () {
      // On Linux/macOS there is no /data/user/0/... to guess at.
      expect(androidDataDirFallback(), isNull);
    });
  });

  group('action ids', () {
    test('match the documented contract', () {
      expect(kActionTaken, 'taken');
      expect(kActionSnooze, 'snooze');
      expect(kActionSkip, 'skip');
      expect(kActionLogWater, 'log_water');
      expect(kActionDismiss, 'dismiss');
    });
  });

  // The background isolate writes to the same file the running app owns; these
  // cover the hand-back so a tap from the shade is never overwritten.
  group('mergeExternalChanges', () {
    test('adopts a dose the isolate resolved while the app was open', () {
      final mine = sampleData();
      final onDisk = sampleData(records: <String, DoseRecord>{
        doseKey: DoseRecord(
          key: doseKey,
          status: DoseStatus.taken,
          actedAt: at(27, 8, 4),
        ),
      });

      final merged = mergeExternalChanges(mine, onDisk);

      expect(merged, isNotNull);
      expect(merged!.records[doseKey]!.status, DoseStatus.taken);
      expect(merged.records[doseKey]!.actedAt, at(27, 8, 4));
    });

    test('adopts a snooze recorded from the shade', () {
      final onDisk = sampleData(records: <String, DoseRecord>{
        doseKey: DoseRecord(key: doseKey, snoozedUntil: at(27, 8, 13)),
      });

      final merged = mergeExternalChanges(sampleData(), onDisk);

      expect(merged!.records[doseKey]!.snoozedUntil, at(27, 8, 13));
      expect(merged.records[doseKey]!.status, DoseStatus.pending);
    });

    test('never overwrites a decision the app already made', () {
      final mine = sampleData(records: <String, DoseRecord>{
        doseKey: DoseRecord(
          key: doseKey,
          status: DoseStatus.skipped,
          actedAt: at(27, 8, 2),
        ),
      });
      final onDisk = sampleData(records: <String, DoseRecord>{
        doseKey: DoseRecord(
          key: doseKey,
          status: DoseStatus.taken,
          actedAt: at(27, 8, 4),
        ),
      });

      expect(mergeExternalChanges(mine, onDisk), isNull);
    });

    test('appends water logged by the isolate without duplicating ours', () {
      final shared = WaterEntry(at: at(27, 9, 0), ml: 250);
      final mine = sampleData().copyWith(water: <WaterEntry>[shared]);
      final onDisk = sampleData().copyWith(water: <WaterEntry>[
        shared,
        WaterEntry(at: at(27, 11, 0), ml: 250),
      ]);

      final merged = mergeExternalChanges(mine, onDisk);

      expect(merged!.water, hasLength(2));
      expect(merged.water.last.at, at(27, 11, 0));
    });

    test('returns null when disk has nothing new', () {
      final data = sampleData(records: <String, DoseRecord>{
        doseKey: DoseRecord(key: doseKey, status: DoseStatus.taken),
      });

      expect(mergeExternalChanges(data, data), isNull);
      expect(mergeExternalChanges(sampleData(), sampleData()), isNull);
    });

    test('leaves meds and settings to the app', () {
      final mine = sampleData();
      final onDisk = AppData(
        meds: const <Medication>[],
        settings: const AppSettings(graceMin: 5),
        waterSettings: const WaterSettings(goalMl: 99),
        records: <String, DoseRecord>{
          doseKey: DoseRecord(key: doseKey, status: DoseStatus.taken),
        },
      );

      final merged = mergeExternalChanges(mine, onDisk);

      expect(merged!.meds, hasLength(1));
      expect(merged.settings.graceMin, const AppSettings().graceMin);
      expect(merged.waterSettings.goalMl, const WaterSettings().goalMl);
    });
  });
}
