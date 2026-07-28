/// Core domain models for DoseDrop.
///
/// Deliberately **pure Dart** (no Flutter imports): these types are used from
/// the Android background-notification isolate, from `StorageService` and from
/// unit tests, so nothing here may depend on `dart:ui`.
///
/// ### Time convention
/// Every `DateTime` in this app is **local wall-clock and timezone-naive**:
/// built with `DateTime(y, m, d, h, min)`, serialised without a zone suffix and
/// compared as-is. Day arithmetic goes through [Days] so DST shifts cannot move
/// a dose to the wrong calendar day.
library;

// ---------------------------------------------------------------------------
// JSON helpers — every reader is null-safe and falls back to a default.
// ---------------------------------------------------------------------------

Map<String, dynamic> _asMap(Object? value) => value is Map
    ? value.map((k, v) => MapEntry<String, dynamic>(k.toString(), v))
    : const <String, dynamic>{};

String _readString(Map<String, dynamic> json, String key, [String fallback = '']) {
  final v = json[key];
  return v is String ? v : fallback;
}

int _readInt(Map<String, dynamic> json, String key, int fallback) {
  final v = json[key];
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

bool _readBool(Map<String, dynamic> json, String key, bool fallback) {
  final v = json[key];
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    if (v == 'true') return true;
    if (v == 'false') return false;
  }
  return fallback;
}

/// Parses an ISO-8601 string into a local, timezone-naive [DateTime].
DateTime? _readDate(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is! String || v.isEmpty) return null;
  final parsed = DateTime.tryParse(v);
  if (parsed == null) return null;
  return parsed.isUtc ? parsed.toLocal() : parsed;
}

List<String> _readStringList(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is! List) return const <String>[];
  return <String>[
    for (final item in v)
      if (item is String) item,
  ];
}

Set<int> _readIntSet(Map<String, dynamic> json, String key, Set<int> fallback) {
  final v = json[key];
  if (v is! List) return fallback;
  final out = <int>{};
  for (final item in v) {
    if (item is int) {
      out.add(item);
    } else if (item is num) {
      out.add(item.toInt());
    } else if (item is String) {
      final parsed = int.tryParse(item);
      if (parsed != null) out.add(parsed);
    }
  }
  return out.isEmpty ? fallback : out;
}

String? _dateToJson(DateTime? value) => value?.toIso8601String();

// ---------------------------------------------------------------------------
// Small shared utilities
// ---------------------------------------------------------------------------

/// Helpers for the `"HH:mm"` strings stored in [Medication.times].
class HhMm {
  HhMm._();

  static const int minutesPerDay = 1440;

  /// Parses `"HH:mm"` into minutes since midnight; `null` when malformed.
  static int? tryParse(String? value) {
    if (value == null) return null;
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    if (h < 0 || h > 23 || m < 0 || m > 59) return null;
    return h * 60 + m;
  }

  /// Formats minutes-since-midnight as `"HH:mm"` (wraps at 24 h).
  static String format(int minutesOfDay) {
    final m = ((minutesOfDay % minutesPerDay) + minutesPerDay) % minutesPerDay;
    final hh = (m ~/ 60).toString().padLeft(2, '0');
    final mm = (m % 60).toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// The `"HH:mm"` wall-clock time of [time].
  static String fromDateTime(DateTime time) =>
      format(time.hour * 60 + time.minute);

  /// Chronological comparator for `"HH:mm"` strings; malformed values sort last.
  static int compare(String a, String b) =>
      (tryParse(a) ?? minutesPerDay).compareTo(tryParse(b) ?? minutesPerDay);
}

/// Local-date helpers. All arithmetic is calendar based (DST safe).
class Days {
  Days._();

  /// Midnight of [time]'s calendar day.
  static DateTime startOf(DateTime time) =>
      DateTime(time.year, time.month, time.day);

  /// Midnight of the day [count] calendar days after [day] (negative goes back).
  static DateTime add(DateTime day, int count) =>
      DateTime(day.year, day.month, day.day + count);

  /// True when both instants fall on the same calendar day.
  static bool same(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Whole calendar days from [from] to [to]; positive when [to] is later.
  static int diffInDays(DateTime from, DateTime to) =>
      DateTime.utc(to.year, to.month, to.day)
          .difference(DateTime.utc(from.year, from.month, from.day))
          .inDays;
}

/// The three parts encoded in a dose key.
typedef DoseKeyParts = ({String medId, DateTime day, String time});

/// The `"<medId>|<yyyy-MM-dd>|<HH:mm>"` identity of a single scheduled dose.
///
/// Used as the [DoseRecord] key and (hashed) as the notification id, so the
/// format is a hard contract across every layer.
class DoseKey {
  DoseKey._();

  static const String separator = '|';

  /// `yyyy-MM-dd` of [day].
  static String dayString(DateTime day) {
    final y = day.year.toString().padLeft(4, '0');
    final m = day.month.toString().padLeft(2, '0');
    final d = day.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Builds the key for [medId] on [day] at [time] (`"HH:mm"`).
  static String build(String medId, DateTime day, String time) =>
      '$medId$separator${dayString(day)}$separator$time';

  /// Builds the key for the dose scheduled at the local instant [scheduledAt].
  static String forInstant(String medId, DateTime scheduledAt) =>
      build(medId, scheduledAt, HhMm.fromDateTime(scheduledAt));

  /// Splits a key back into its parts; `null` when it is not a valid key.
  static DoseKeyParts? tryParse(String key) {
    final parts = key.split(separator);
    if (parts.length != 3) return null;
    final medId = parts[0];
    final date = parts[1].split('-');
    if (medId.isEmpty || date.length != 3) return null;
    final y = int.tryParse(date[0]);
    final mo = int.tryParse(date[1]);
    final d = int.tryParse(date[2]);
    if (y == null || mo == null || d == null) return null;
    if (HhMm.tryParse(parts[2]) == null) return null;
    return (medId: medId, day: DateTime(y, mo, d), time: parts[2]);
  }

  /// The local instant a key points at (its day + its `"HH:mm"`), if parseable.
  static DateTime? scheduledAtOf(String key) {
    final parts = tryParse(key);
    if (parts == null) return null;
    final minutes = HhMm.tryParse(parts.time)!;
    return DateTime(parts.day.year, parts.day.month, parts.day.day,
        minutes ~/ 60, minutes % 60);
  }
}

// ---------------------------------------------------------------------------
// Medication
// ---------------------------------------------------------------------------

/// A medication and its recurring schedule.
class Medication {
  /// Number of med identity colors in the palette (see `DD.medColors`).
  static const int colorCount = 6;

  /// Mon–Sun, the default recurrence.
  static const Set<int> everyDay = <int>{1, 2, 3, 4, 5, 6, 7};

  final String id;
  final String name;

  /// Free text, e.g. `"500 mg · 1 tablet"`.
  final String dosage;

  /// Index into the fixed med color palette (0–5). Follows the med forever.
  final int colorIndex;

  /// Times of day as `"HH:mm"` strings.
  final List<String> times;

  /// Weekdays this med repeats on, `DateTime.monday` (1) … `DateTime.sunday` (7).
  final Set<int> days;

  final bool enabled;
  final String notes;

  const Medication({
    required this.id,
    required this.name,
    this.dosage = '',
    this.colorIndex = 0,
    this.times = const <String>[],
    this.days = everyDay,
    this.enabled = true,
    this.notes = '',
  });

  /// [times] in chronological order (malformed entries last).
  List<String> get sortedTimes => <String>[...times]..sort(HhMm.compare);

  /// True when this med has at least one usable time and one weekday.
  bool get isSchedulable =>
      days.isNotEmpty && times.any((t) => HhMm.tryParse(t) != null);

  Medication copyWith({
    String? id,
    String? name,
    String? dosage,
    int? colorIndex,
    List<String>? times,
    Set<int>? days,
    bool? enabled,
    String? notes,
  }) =>
      Medication(
        id: id ?? this.id,
        name: name ?? this.name,
        dosage: dosage ?? this.dosage,
        colorIndex: colorIndex ?? this.colorIndex,
        times: times ?? this.times,
        days: days ?? this.days,
        enabled: enabled ?? this.enabled,
        notes: notes ?? this.notes,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'dosage': dosage,
        'colorIndex': colorIndex,
        'times': times,
        'days': days.toList()..sort(),
        'enabled': enabled,
        'notes': notes,
      };

  factory Medication.fromJson(Map<String, dynamic> json) {
    final rawColor = _readInt(json, 'colorIndex', 0);
    final days = _readIntSet(json, 'days', everyDay)
        .where((d) => d >= DateTime.monday && d <= DateTime.sunday)
        .toSet();
    return Medication(
      id: _readString(json, 'id'),
      name: _readString(json, 'name'),
      dosage: _readString(json, 'dosage'),
      colorIndex: rawColor >= 0 && rawColor < colorCount ? rawColor : 0,
      times: _readStringList(json, 'times'),
      days: days.isEmpty ? everyDay : days,
      enabled: _readBool(json, 'enabled', true),
      notes: _readString(json, 'notes'),
    );
  }

  @override
  String toString() => 'Medication($id, $name, times: $times, days: $days)';
}

// ---------------------------------------------------------------------------
// Dose record + slot
// ---------------------------------------------------------------------------

/// Lifecycle of a single scheduled dose.
enum DoseStatus {
  /// Not resolved yet (possibly snoozed).
  pending,
  taken,
  skipped,

  /// The grace window expired without an action (see `ScheduleEngine.sweepMissed`).
  missed;

  /// True once the dose is resolved — taken, skipped or missed.
  bool get isActed => this != DoseStatus.pending;

  /// Tolerant parse: anything unknown becomes [pending].
  static DoseStatus fromName(Object? name) {
    for (final status in values) {
      if (status.name == name) return status;
    }
    return DoseStatus.pending;
  }
}

/// What the user did (or didn't do) about one scheduled dose.
///
/// Only doses that have been acted on or snoozed need a record; a missing
/// record is equivalent to [DoseStatus.pending] with no snooze.
class DoseRecord {
  /// `"<medId>|<yyyy-MM-dd>|<HH:mm>"` — see [DoseKey].
  final String key;
  final DoseStatus status;

  /// When the status was set (also the sweep time for [DoseStatus.missed]).
  final DateTime? actedAt;

  /// While [status] is [DoseStatus.pending], the dose is due at this instant
  /// instead of its scheduled time.
  final DateTime? snoozedUntil;

  const DoseRecord({
    required this.key,
    this.status = DoseStatus.pending,
    this.actedAt,
    this.snoozedUntil,
  });

  bool get isActed => status.isActed;

  /// True when a snooze is currently in force (only meaningful while pending).
  bool get isSnoozed => snoozedUntil != null && !status.isActed;

  DoseRecord copyWith({
    String? key,
    DoseStatus? status,
    DateTime? actedAt,
    DateTime? snoozedUntil,
    bool clearActedAt = false,
    bool clearSnoozedUntil = false,
  }) =>
      DoseRecord(
        key: key ?? this.key,
        status: status ?? this.status,
        actedAt: clearActedAt ? null : (actedAt ?? this.actedAt),
        snoozedUntil:
            clearSnoozedUntil ? null : (snoozedUntil ?? this.snoozedUntil),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'status': status.name,
        'actedAt': _dateToJson(actedAt),
        'snoozedUntil': _dateToJson(snoozedUntil),
      };

  /// [fallbackKey] is used when the object itself has no `key` (e.g. when the
  /// record was stored in a map keyed by dose key).
  factory DoseRecord.fromJson(Map<String, dynamic> json,
          {String fallbackKey = ''}) =>
      DoseRecord(
        key: _readString(json, 'key', fallbackKey),
        status: DoseStatus.fromName(json['status']),
        actedAt: _readDate(json, 'actedAt'),
        snoozedUntil: _readDate(json, 'snoozedUntil'),
      );

  @override
  String toString() => 'DoseRecord($key, ${status.name}, '
      'actedAt: $actedAt, snoozedUntil: $snoozedUntil)';
}

/// One occurrence of a [Medication] at a concrete local instant.
///
/// Computed by `ScheduleEngine`, never persisted — the persisted counterpart is
/// the [DoseRecord] found under [key].
class DoseSlot {
  final Medication med;

  /// Local wall-clock instant this dose is scheduled for.
  final DateTime scheduledAt;

  const DoseSlot({required this.med, required this.scheduledAt});

  /// `"HH:mm"` of [scheduledAt].
  String get time => HhMm.fromDateTime(scheduledAt);

  /// Midnight of the day this dose belongs to.
  DateTime get day => Days.startOf(scheduledAt);

  /// `"<medId>|<yyyy-MM-dd>|<HH:mm>"` — the key of this slot's [DoseRecord].
  String get key => DoseKey.build(med.id, scheduledAt, time);

  @override
  bool operator ==(Object other) =>
      other is DoseSlot &&
      other.scheduledAt == scheduledAt &&
      other.med.id == med.id;

  @override
  int get hashCode => Object.hash(med.id, scheduledAt);

  @override
  String toString() => 'DoseSlot(${med.name} @ $scheduledAt)';
}

// ---------------------------------------------------------------------------
// Water
// ---------------------------------------------------------------------------

/// A logged drink.
class WaterEntry {
  final DateTime at;
  final int ml;

  const WaterEntry({required this.at, required this.ml});

  WaterEntry copyWith({DateTime? at, int? ml}) =>
      WaterEntry(at: at ?? this.at, ml: ml ?? this.ml);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'at': at.toIso8601String(),
        'ml': ml,
      };

  factory WaterEntry.fromJson(Map<String, dynamic> json) => WaterEntry(
        at: _readDate(json, 'at') ?? DateTime.fromMillisecondsSinceEpoch(0),
        ml: _readInt(json, 'ml', 0),
      );

  @override
  String toString() => 'WaterEntry($at, $ml ml)';
}

/// Water reminder + goal configuration. Defaults per PLAN.md.
class WaterSettings {
  final bool enabled;
  final int goalMl;

  /// Quick-add amount for the primary "+" chip.
  final int cupMl;

  /// Minutes between reminders during active hours.
  final int intervalMin;

  /// First reminder, minutes since midnight (480 = 08:00).
  final int activeStartMin;

  /// Last reminder, minutes since midnight, inclusive (1320 = 22:00).
  final int activeEndMin;

  const WaterSettings({
    this.enabled = true,
    this.goalMl = 2000,
    this.cupMl = 250,
    this.intervalMin = 60,
    this.activeStartMin = 480,
    this.activeEndMin = 1320,
  });

  /// `"HH:mm"` of [activeStartMin].
  String get activeStartLabel => HhMm.format(activeStartMin);

  /// `"HH:mm"` of [activeEndMin].
  String get activeEndLabel => HhMm.format(activeEndMin);

  WaterSettings copyWith({
    bool? enabled,
    int? goalMl,
    int? cupMl,
    int? intervalMin,
    int? activeStartMin,
    int? activeEndMin,
  }) =>
      WaterSettings(
        enabled: enabled ?? this.enabled,
        goalMl: goalMl ?? this.goalMl,
        cupMl: cupMl ?? this.cupMl,
        intervalMin: intervalMin ?? this.intervalMin,
        activeStartMin: activeStartMin ?? this.activeStartMin,
        activeEndMin: activeEndMin ?? this.activeEndMin,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'goalMl': goalMl,
        'cupMl': cupMl,
        'intervalMin': intervalMin,
        'activeStartMin': activeStartMin,
        'activeEndMin': activeEndMin,
      };

  factory WaterSettings.fromJson(Map<String, dynamic> json) {
    const defaults = WaterSettings();
    return WaterSettings(
      enabled: _readBool(json, 'enabled', defaults.enabled),
      goalMl: _readInt(json, 'goalMl', defaults.goalMl),
      cupMl: _readInt(json, 'cupMl', defaults.cupMl),
      intervalMin: _readInt(json, 'intervalMin', defaults.intervalMin),
      activeStartMin: _readInt(json, 'activeStartMin', defaults.activeStartMin),
      activeEndMin: _readInt(json, 'activeEndMin', defaults.activeEndMin),
    );
  }
}

// ---------------------------------------------------------------------------
// App settings
// ---------------------------------------------------------------------------

/// Theme preference. Kept Flutter-free on purpose; the UI layer maps it, e.g.
/// `switch (pref) { AppThemeMode.system => ThemeMode.system, ... }`.
enum AppThemeMode {
  system,
  light,
  dark;

  /// Tolerant parse: anything unknown becomes [system].
  static AppThemeMode fromName(Object? name) {
    for (final mode in values) {
      if (mode.name == name) return mode;
    }
    return AppThemeMode.system;
  }
}

/// Reminder behaviour + app preferences. Defaults per PLAN.md.
class AppSettings {
  /// Fixed snooze length ("Snooze 10 min" in DESIGN.md); not user-tunable in v1.
  static const int snoozeMinutes = 10;

  /// Minutes between escalating re-alerts for an unconfirmed dose.
  final int nagIntervalMin;

  /// How many re-alerts follow the first notification.
  final int nagMaxCount;

  /// Minutes after the due time before a dose is auto-marked missed.
  final int graceMin;

  final bool alarmSound;
  final AppThemeMode themeMode;

  /// Desktop only: launch DoseDrop at login.
  final bool autostart;

  /// All reminders are suppressed until this instant ("Pause 1 hour" in the
  /// tray menu). `null` (the default) means reminders are active.
  ///
  /// Only alerting is paused: doses are still scheduled, swept and recorded, so
  /// history stays honest.
  final DateTime? pausedUntil;

  const AppSettings({
    this.nagIntervalMin = 5,
    this.nagMaxCount = 3,
    this.graceMin = 60,
    this.alarmSound = true,
    this.themeMode = AppThemeMode.system,
    this.autostart = false,
    this.pausedUntil,
  });

  Duration get nagInterval => Duration(minutes: nagIntervalMin);
  Duration get grace => Duration(minutes: graceMin);
  Duration get snooze => const Duration(minutes: snoozeMinutes);

  /// True when reminders are currently paused as of [now].
  bool isPausedAt(DateTime now) {
    final until = pausedUntil;
    return until != null && now.isBefore(until);
  }

  AppSettings copyWith({
    int? nagIntervalMin,
    int? nagMaxCount,
    int? graceMin,
    bool? alarmSound,
    AppThemeMode? themeMode,
    bool? autostart,
    DateTime? pausedUntil,
    bool clearPausedUntil = false,
  }) =>
      AppSettings(
        nagIntervalMin: nagIntervalMin ?? this.nagIntervalMin,
        nagMaxCount: nagMaxCount ?? this.nagMaxCount,
        graceMin: graceMin ?? this.graceMin,
        alarmSound: alarmSound ?? this.alarmSound,
        themeMode: themeMode ?? this.themeMode,
        autostart: autostart ?? this.autostart,
        pausedUntil:
            clearPausedUntil ? null : (pausedUntil ?? this.pausedUntil),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'nagIntervalMin': nagIntervalMin,
        'nagMaxCount': nagMaxCount,
        'graceMin': graceMin,
        'alarmSound': alarmSound,
        'themeMode': themeMode.name,
        'autostart': autostart,
        'pausedUntil': _dateToJson(pausedUntil),
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    const defaults = AppSettings();
    return AppSettings(
      nagIntervalMin: _readInt(json, 'nagIntervalMin', defaults.nagIntervalMin),
      nagMaxCount: _readInt(json, 'nagMaxCount', defaults.nagMaxCount),
      graceMin: _readInt(json, 'graceMin', defaults.graceMin),
      alarmSound: _readBool(json, 'alarmSound', defaults.alarmSound),
      themeMode: AppThemeMode.fromName(json['themeMode']),
      autostart: _readBool(json, 'autostart', defaults.autostart),
      pausedUntil: _readDate(json, 'pausedUntil'),
    );
  }
}

// ---------------------------------------------------------------------------
// AppData — everything that is persisted
// ---------------------------------------------------------------------------

/// The whole persisted state, as written to `dose_drop_data.json`.
///
/// Immutable: mutations go through [copyWith] so `AppState` can hand a fresh
/// snapshot to listeners.
class AppData {
  /// On-disk schema version; bump when a migration becomes necessary.
  static const int schemaVersion = 1;

  /// Fresh state with every default applied — a first run, or an unreadable file.
  static const AppData empty = AppData();

  final List<Medication> meds;

  /// Dose records by [DoseKey]; absent means pending.
  final Map<String, DoseRecord> records;

  final List<WaterEntry> water;
  final WaterSettings waterSettings;
  final AppSettings settings;

  const AppData({
    this.meds = const <Medication>[],
    this.records = const <String, DoseRecord>{},
    this.water = const <WaterEntry>[],
    this.waterSettings = const WaterSettings(),
    this.settings = const AppSettings(),
  });

  /// The record for [key], or `null` when the dose has not been acted on.
  DoseRecord? recordFor(String key) => records[key];

  Medication? medById(String id) {
    for (final med in meds) {
      if (med.id == id) return med;
    }
    return null;
  }

  AppData copyWith({
    List<Medication>? meds,
    Map<String, DoseRecord>? records,
    List<WaterEntry>? water,
    WaterSettings? waterSettings,
    AppSettings? settings,
  }) =>
      AppData(
        meds: meds ?? this.meds,
        records: records ?? this.records,
        water: water ?? this.water,
        waterSettings: waterSettings ?? this.waterSettings,
        settings: settings ?? this.settings,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': schemaVersion,
        'meds': [for (final med in meds) med.toJson()],
        'records': <String, dynamic>{
          for (final entry in records.entries) entry.key: entry.value.toJson(),
        },
        'water': [for (final entry in water) entry.toJson()],
        'waterSettings': waterSettings.toJson(),
        'settings': settings.toJson(),
      };

  /// Tolerant of anything: missing, misspelled or wrongly typed keys all fall
  /// back to defaults. Meds without an `id` and unkeyed records are dropped.
  factory AppData.fromJson(Map<String, dynamic> json) {
    final meds = <Medication>[];
    final rawMeds = json['meds'];
    if (rawMeds is List) {
      for (final item in rawMeds) {
        if (item is! Map) continue;
        final med = Medication.fromJson(_asMap(item));
        if (med.id.isEmpty) continue;
        meds.add(med);
      }
    }

    final records = <String, DoseRecord>{};
    final rawRecords = json['records'];
    if (rawRecords is Map) {
      for (final entry in rawRecords.entries) {
        if (entry.value is! Map) continue;
        final record = DoseRecord.fromJson(
          _asMap(entry.value),
          fallbackKey: entry.key.toString(),
        );
        if (record.key.isEmpty) continue;
        records[record.key] = record;
      }
    }

    final water = <WaterEntry>[];
    final rawWater = json['water'];
    if (rawWater is List) {
      for (final item in rawWater) {
        if (item is! Map) continue;
        water.add(WaterEntry.fromJson(_asMap(item)));
      }
    }

    return AppData(
      meds: meds,
      records: records,
      water: water,
      waterSettings: WaterSettings.fromJson(_asMap(json['waterSettings'])),
      settings: AppSettings.fromJson(_asMap(json['settings'])),
    );
  }
}
