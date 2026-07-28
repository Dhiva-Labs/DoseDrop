import 'dart:convert';
import 'dart:io';

import 'package:dose_drop/models/models.dart';
import 'package:dose_drop/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

AppData buildSampleData() {
  final med = Medication(
    id: 'med-1',
    name: 'Metformin',
    dosage: '500 mg · 1 tablet',
    colorIndex: 3,
    times: const <String>['08:00', '20:00'],
    days: const <int>{1, 3, 5},
    notes: 'After food',
  );
  final vitamin = Medication(
    id: 'med-2',
    name: 'Vitamin D',
    times: const <String>['09:30'],
    enabled: false,
  );
  final taken = DoseRecord(
    key: DoseKey.build(med.id, DateTime(2026, 7, 27), '08:00'),
    status: DoseStatus.taken,
    actedAt: DateTime(2026, 7, 27, 8, 4),
  );
  final snoozed = DoseRecord(
    key: DoseKey.build(med.id, DateTime(2026, 7, 27), '20:00'),
    snoozedUntil: DateTime(2026, 7, 27, 20, 10),
  );

  return AppData(
    meds: <Medication>[med, vitamin],
    records: <String, DoseRecord>{taken.key: taken, snoozed.key: snoozed},
    water: <WaterEntry>[
      WaterEntry(at: DateTime(2026, 7, 27, 9, 0), ml: 250),
      WaterEntry(at: DateTime(2026, 7, 27, 11, 30), ml: 500),
    ],
    waterSettings: const WaterSettings(goalMl: 2500, intervalMin: 90),
    settings: AppSettings(
      nagIntervalMin: 7,
      nagMaxCount: 2,
      graceMin: 45,
      alarmSound: false,
      themeMode: AppThemeMode.dark,
      autostart: true,
      pausedUntil: DateTime(2026, 7, 27, 21, 0),
    ),
  );
}

void expectDefaults(AppData data) {
  expect(data.meds, isEmpty);
  expect(data.records, isEmpty);
  expect(data.water, isEmpty);
  expect(data.waterSettings.goalMl, 2000);
  expect(data.waterSettings.cupMl, 250);
  expect(data.waterSettings.intervalMin, 60);
  expect(data.waterSettings.activeStartMin, 480);
  expect(data.waterSettings.activeEndMin, 1320);
  expect(data.waterSettings.enabled, isTrue);
  expect(data.settings.nagIntervalMin, 5);
  expect(data.settings.nagMaxCount, 3);
  expect(data.settings.graceMin, 60);
  expect(data.settings.alarmSound, isTrue);
  expect(data.settings.themeMode, AppThemeMode.system);
  expect(data.settings.autostart, isFalse);
  expect(data.settings.pausedUntil, isNull);
}

void main() {
  late Directory dir;
  late StorageService storage;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dose_drop_test');
    storage = StorageService(dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('paths', () {
    test('writes dose_drop_data.json inside the given directory', () {
      expect(storage.filePath, '${dir.path}${Platform.pathSeparator}dose_drop_data.json');
      expect(StorageService.pathFor('${dir.path}${Platform.pathSeparator}'),
          storage.filePath);
    });
  });

  group('roundtrip', () {
    test('save then load returns identical data', () async {
      final original = buildSampleData();

      await storage.save(original);
      final loaded = await storage.load();

      expect(jsonEncode(loaded.toJson()), jsonEncode(original.toJson()));
      expect(loaded.meds, hasLength(2));
      expect(loaded.meds.first.name, 'Metformin');
      expect(loaded.meds.first.days, const <int>{1, 3, 5});
      expect(loaded.meds.first.colorIndex, 3);
      expect(loaded.meds.first.notes, 'After food');
      expect(loaded.meds.last.enabled, isFalse);
      expect(loaded.records, hasLength(2));
      expect(loaded.records['med-1|2026-07-27|08:00']?.status, DoseStatus.taken);
      expect(loaded.records['med-1|2026-07-27|08:00']?.actedAt,
          DateTime(2026, 7, 27, 8, 4));
      expect(loaded.records['med-1|2026-07-27|20:00']?.status,
          DoseStatus.pending);
      expect(loaded.records['med-1|2026-07-27|20:00']?.snoozedUntil,
          DateTime(2026, 7, 27, 20, 10));
      expect(loaded.water.map((e) => e.ml).toList(), [250, 500]);
      expect(loaded.water.first.at, DateTime(2026, 7, 27, 9, 0));
      expect(loaded.waterSettings.goalMl, 2500);
      expect(loaded.waterSettings.intervalMin, 90);
      expect(loaded.settings.graceMin, 45);
      expect(loaded.settings.themeMode, AppThemeMode.dark);
      expect(loaded.settings.autostart, isTrue);
      expect(loaded.settings.alarmSound, isFalse);
      expect(loaded.settings.pausedUntil, DateTime(2026, 7, 27, 21, 0));
    });

    test('a pause can be cleared and round-trips as absent', () async {
      final data = buildSampleData();
      await storage.save(data.copyWith(
        settings: data.settings.copyWith(clearPausedUntil: true),
      ));

      final loaded = await storage.load();

      expect(loaded.settings.pausedUntil, isNull);
      expect(loaded.settings.isPausedAt(DateTime(2026, 7, 27, 20, 0)), isFalse);
    });

    test('a stored pause is honoured only until it expires', () async {
      await storage.save(buildSampleData());

      final settings = (await storage.load()).settings;

      expect(settings.isPausedAt(DateTime(2026, 7, 27, 20, 59)), isTrue);
      expect(settings.isPausedAt(DateTime(2026, 7, 27, 21, 0)), isFalse);
      expect(settings.isPausedAt(DateTime(2026, 7, 27, 21, 1)), isFalse);
    });

    test('a second save overwrites the first', () async {
      await storage.save(buildSampleData());
      await storage.save(AppData.empty.copyWith(
        meds: <Medication>[const Medication(id: 'only', name: 'Only')],
      ));

      final loaded = await storage.load();

      expect(loaded.meds.map((m) => m.id).toList(), ['only']);
      expect(loaded.records, isEmpty);
    });

    test('dates stay on local wall-clock time', () async {
      final at = DateTime(2026, 12, 31, 23, 45);
      await storage.save(AppData.empty.copyWith(
        water: <WaterEntry>[WaterEntry(at: at, ml: 250)],
      ));

      final loaded = await storage.load();

      expect(loaded.water.single.at, at);
      expect(loaded.water.single.at.isUtc, isFalse);
    });
  });

  group('resilience', () {
    test('a missing file loads fresh defaults', () async {
      expect(await storage.file.exists(), isFalse);

      expectDefaults(await storage.load());
    });

    test('corrupt JSON loads fresh defaults', () async {
      await storage.file.writeAsString('{"meds": [{"id": "x"');

      expectDefaults(await storage.load());
    });

    test('an empty file loads fresh defaults', () async {
      await storage.file.writeAsString('   \n');

      expectDefaults(await storage.load());
    });

    test('valid JSON of the wrong shape loads fresh defaults', () async {
      await storage.file.writeAsString('[1, 2, 3]');

      expectDefaults(await storage.load());
    });

    test('a truncated but valid JSON object loads what it can', () async {
      await storage.file.writeAsString(jsonEncode(<String, dynamic>{
        'meds': <dynamic>[
          <String, dynamic>{'id': 'm1', 'name': 'Aspirin'},
          <String, dynamic>{'name': 'No id — dropped'},
          'not a map',
        ],
        'settings': <String, dynamic>{'graceMin': 30, 'unknown': 'ignored'},
      }));

      final loaded = await storage.load();

      expect(loaded.meds, hasLength(1));
      expect(loaded.meds.single.id, 'm1');
      // Missing keys fall back to model defaults.
      expect(loaded.meds.single.times, isEmpty);
      expect(loaded.meds.single.days, Medication.everyDay);
      expect(loaded.meds.single.enabled, isTrue);
      expect(loaded.meds.single.colorIndex, 0);
      expect(loaded.meds.single.dosage, '');
      expect(loaded.settings.graceMin, 30);
      expect(loaded.settings.nagIntervalMin, 5);
      expect(loaded.settings.themeMode, AppThemeMode.system);
      expect(loaded.waterSettings.goalMl, 2000);
    });

    test('wrongly typed and unknown values fall back per field', () async {
      await storage.file.writeAsString(jsonEncode(<String, dynamic>{
        'meds': <dynamic>[
          <String, dynamic>{
            'id': 'm1',
            'name': 'Aspirin',
            'colorIndex': '42',
            'times': <dynamic>['08:00', 7, null],
            'days': <dynamic>['1', 9, 3],
            'enabled': 'false',
          },
        ],
        'records': <String, dynamic>{
          'm1|2026-07-27|08:00': <String, dynamic>{
            'status': 'levitating',
            'actedAt': 'not a date',
          },
        },
        'water': <dynamic>[
          <String, dynamic>{'ml': 250},
        ],
        'waterSettings': 'nonsense',
      }));

      final loaded = await storage.load();

      expect(loaded.meds.single.colorIndex, 0); // out of palette range
      expect(loaded.meds.single.times, ['08:00']); // non-strings dropped
      expect(loaded.meds.single.days, const <int>{1, 3}); // 9 is not a weekday
      expect(loaded.meds.single.enabled, isFalse);
      // The map key is used when the record object has no "key" of its own.
      final record = loaded.records['m1|2026-07-27|08:00'];
      expect(record, isNotNull);
      expect(record!.key, 'm1|2026-07-27|08:00');
      expect(record.status, DoseStatus.pending);
      expect(record.actedAt, isNull);
      expect(loaded.water.single.ml, 250);
      expect(loaded.waterSettings.goalMl, 2000);
    });

    test('an unreadable directory still yields defaults', () async {
      final missing = StorageService(
        Directory('${dir.path}${Platform.pathSeparator}nope'),
      );

      expectDefaults(await missing.load());
    });
  });

  group('atomic write', () {
    File tmpFile() => File('${storage.filePath}${StorageService.tmpSuffix}');

    test('leaves no .tmp file behind', () async {
      await storage.save(buildSampleData());

      expect(await storage.file.exists(), isTrue);
      expect(await tmpFile().exists(), isFalse);
      final names = await dir
          .list()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .toList();
      expect(names, ['dose_drop_data.json']);
    });

    test('a stale .tmp file from a crashed write is replaced', () async {
      await tmpFile().writeAsString('half-written garbage');

      await storage.save(buildSampleData());

      expect(await tmpFile().exists(), isFalse);
      expect((await storage.load()).meds, hasLength(2));
    });

    test('the file on disk is always complete JSON', () async {
      await storage.save(buildSampleData());

      final decoded = jsonDecode(await storage.file.readAsString());

      expect(decoded, isA<Map<String, dynamic>>());
      expect((decoded as Map)['version'], AppData.schemaVersion);
    });

    test('creates the directory if it does not exist yet', () async {
      final nested = Directory(
          '${dir.path}${Platform.pathSeparator}a${Platform.pathSeparator}b');
      final nestedStorage = StorageService(nested);

      await nestedStorage.save(buildSampleData());

      expect((await nestedStorage.load()).meds, hasLength(2));
    });
  });

  group('static raw API (background isolate)', () {
    test('saveTo and loadFrom roundtrip through a plain path', () async {
      final original = buildSampleData();

      await StorageService.saveTo(dir.path, original);
      final loaded = await StorageService.loadFrom(dir.path);

      expect(jsonEncode(loaded.toJson()), jsonEncode(original.toJson()));
    });

    test('sees writes made through the instance API and vice versa', () async {
      await storage.save(buildSampleData());

      final raw = await StorageService.loadFrom(dir.path);
      final key = 'med-1|2026-07-27|20:00';
      final updated = raw.copyWith(records: <String, DoseRecord>{
        ...raw.records,
        key: raw.records[key]!.copyWith(
          status: DoseStatus.taken,
          actedAt: DateTime(2026, 7, 27, 20, 12),
          clearSnoozedUntil: true,
        ),
      });
      await StorageService.saveTo(dir.path, updated);

      final reloaded = await storage.load();

      expect(reloaded.records[key]?.status, DoseStatus.taken);
      expect(reloaded.records[key]?.snoozedUntil, isNull);
      expect(reloaded.records[key]?.actedAt, DateTime(2026, 7, 27, 20, 12));
    });

    test('loadFrom a missing directory yields defaults', () async {
      expectDefaults(await StorageService.loadFrom(
          '${dir.path}${Platform.pathSeparator}ghost'));
    });
  });

  group('clear', () {
    test('removes the data file and resets to defaults', () async {
      await storage.save(buildSampleData());

      await storage.clear();

      expect(await storage.file.exists(), isFalse);
      expectDefaults(await storage.load());
      await storage.clear(); // idempotent
    });
  });
}
