// Seeds a realistic demo dataset for screenshots and manual testing.
//
// Usage: dart run tools/seed_demo.dart <supportDir> [light|dark] [dueInMin]
//
// Writes <supportDir>/dose_drop_data.json via the app's own StorageService so
// the payload always matches the current schema. The third med's single dose
// is scheduled [dueInMin] minutes from now (default 4) so the Today screen
// shows a live countdown and the alarm can be observed firing shortly after.
import 'dart:io';

import 'package:dose_drop/models/models.dart';
import 'package:dose_drop/services/storage_service.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tools/seed_demo.dart <supportDir> '
        '[light|dark] [dueInMin]');
    exit(64);
  }
  final dir = args[0];
  final dark = args.length > 1 && args[1] == 'dark';
  final dueInMin = args.length > 2 ? int.parse(args[2]) : 4;

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final omegaTime = HhMm.fromDateTime(now.add(Duration(minutes: dueInMin)));

  const vitD = Medication(
    id: 'demo-vitd',
    name: 'Vitamin D3',
    dosage: '1000 IU · 1 tablet',
    colorIndex: 0,
    times: ['08:00'],
  );
  const metformin = Medication(
    id: 'demo-metf',
    name: 'Metformin',
    dosage: '500 mg · 1 tablet',
    colorIndex: 1,
    times: ['08:00', '20:00'],
  );
  final omega = Medication(
    id: 'demo-omega',
    name: 'Omega-3',
    dosage: '1 capsule',
    colorIndex: 2,
    times: [omegaTime],
  );
  final meds = [vitD, metformin, omega];

  final records = <String, DoseRecord>{};
  void mark(Medication med, DateTime day, String time, DoseStatus status,
      {int lateMin = 4}) {
    final key = DoseKey.build(med.id, day, time);
    final minutesOfDay = HhMm.tryParse(time)!;
    final at = DateTime(
            day.year, day.month, day.day, minutesOfDay ~/ 60, minutesOfDay % 60)
        .add(Duration(minutes: lateMin));
    records[key] = DoseRecord(key: key, status: status, actedAt: at);
  }

  // Past six days: everything taken, except one evening dose missed three
  // days ago — gives the history a realistic dent and a resettable streak.
  for (var back = 6; back >= 1; back--) {
    final day = today.subtract(Duration(days: back));
    mark(vitD, day, '08:00', DoseStatus.taken);
    mark(metformin, day, '08:00', DoseStatus.taken, lateMin: 7);
    mark(omega, day, omegaTime, DoseStatus.taken, lateMin: 2);
    mark(
      metformin,
      day,
      '20:00',
      back == 3 ? DoseStatus.missed : DoseStatus.taken,
      lateMin: back == 3 ? 65 : 3,
    );
  }
  // Today: the morning doses are already taken; omega (and Metformin 20:00)
  // are still ahead.
  if (now.hour >= 8) {
    mark(vitD, today, '08:00', DoseStatus.taken, lateMin: 5);
    mark(metformin, today, '08:00', DoseStatus.taken, lateMin: 9);
  }

  // Water: partial progress today, varied history with one over-goal day.
  final water = <WaterEntry>[];
  const pastMl = [1750, 2250, 2000, 1500, 1250, 2000];
  for (var back = 6; back >= 1; back--) {
    final day = today.subtract(Duration(days: back));
    final total = pastMl[back - 1];
    for (var ml = 0; ml < total; ml += 250) {
      water.add(WaterEntry(
          at: day.add(Duration(hours: 9, minutes: (ml ~/ 250) * 90)),
          ml: 250));
    }
  }
  for (var i = 0; i < 5; i++) {
    final at = today.add(Duration(hours: 9, minutes: i * 110));
    if (at.isBefore(now)) water.add(WaterEntry(at: at, ml: 250));
  }

  final data = AppData(
    meds: meds,
    records: records,
    water: water,
    settings: AppSettings(
      themeMode: dark ? AppThemeMode.dark : AppThemeMode.light,
    ),
  );

  await StorageService.saveTo(dir, data);
  stdout.writeln('Seeded $dir (${meds.length} meds, ${records.length} records, '
      '${water.length} water entries, omega due $omegaTime, '
      'theme ${dark ? 'dark' : 'light'})');
}
