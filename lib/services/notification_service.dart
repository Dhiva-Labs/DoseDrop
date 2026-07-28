import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/models.dart';
import 'schedule_engine.dart';
import 'storage_service.dart';

// ---------------------------------------------------------------------------
// Action ids — the contract shared with the notification buttons, the
// foreground handler and the background isolate.
// ---------------------------------------------------------------------------

/// "I took it" — resolves the dose as taken.
const String kActionTaken = 'taken';

/// "Snooze 10 min" — re-alerts after [AppSettings.snoozeMinutes].
const String kActionSnooze = 'snooze';

/// "Skip" — resolves the dose as skipped.
const String kActionSkip = 'skip';

/// "Log 250 ml" — adds a water entry of [WaterSettings.cupMl].
const String kActionLogWater = 'log_water';

/// "Dismiss" — clears the notification and does nothing else.
const String kActionDismiss = 'dismiss';

// ---------------------------------------------------------------------------
// Payloads
// ---------------------------------------------------------------------------

/// What a notification refers to, encoded in its payload string.
///
/// Doses use P1's dose key verbatim (`"<medId>|<yyyy-MM-dd>|<HH:mm>"`), water
/// uses `"water|<yyyy-MM-dd>|<HH:mm>"`. Medication ids are UUIDs, so the two
/// forms can never be confused.
sealed class NotificationPayload {
  const NotificationPayload();

  /// Prefix that marks a water payload.
  static const String waterPrefix = 'water';

  /// Decodes a payload string; `null` when it is missing or malformed.
  static NotificationPayload? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('$waterPrefix${DoseKey.separator}')) {
      final parts = raw.split(DoseKey.separator);
      if (parts.length != 3) return null;
      final day = _parseDay(parts[1]);
      final minutes = HhMm.tryParse(parts[2]);
      if (day == null || minutes == null) return null;
      return WaterPayload(
        DateTime(day.year, day.month, day.day, minutes ~/ 60, minutes % 60),
      );
    }
    if (DoseKey.tryParse(raw) == null) return null;
    return DosePayload(raw);
  }

  static DateTime? _parseDay(String value) {
    final parts = value.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  /// The payload string sent to the platform.
  String encode();

  /// The notification id this payload owns (see [NotificationIds]).
  int get notificationId;
}

/// A medication dose, identified by its P1 dose key.
class DosePayload extends NotificationPayload {
  const DosePayload(this.slotKey);

  final String slotKey;

  @override
  String encode() => slotKey;

  @override
  int get notificationId => NotificationIds.forDose(slotKey);

  @override
  bool operator ==(Object other) =>
      other is DosePayload && other.slotKey == slotKey;

  @override
  int get hashCode => slotKey.hashCode;

  @override
  String toString() => 'DosePayload($slotKey)';
}

/// A water reminder for a concrete local instant.
class WaterPayload extends NotificationPayload {
  const WaterPayload(this.at);

  final DateTime at;

  @override
  String encode() => '${NotificationPayload.waterPrefix}'
      '${DoseKey.separator}${DoseKey.dayString(at)}'
      '${DoseKey.separator}${HhMm.fromDateTime(at)}';

  @override
  int get notificationId => NotificationIds.forWater(at);

  @override
  bool operator ==(Object other) => other is WaterPayload && other.at == at;

  @override
  int get hashCode => at.hashCode;

  @override
  String toString() => 'WaterPayload($at)';
}

// ---------------------------------------------------------------------------
// Notification ids
// ---------------------------------------------------------------------------

/// Deterministic notification ids derived from payload strings (PLAN.md).
///
/// Ids must be stable across app restarts and across isolates — the background
/// isolate has to cancel the nags of a slot it only knows by key — so they are
/// hashed, never sequential.
///
/// Ranges (Android ids are signed 32-bit):
/// * doses `0x00000000 – 0x3FFFFFFF`, nag *n* of a dose is `id + n`
/// * water `0x40000000 – 0x7FFFFFFE`
/// * [test] `0x7FFFFFFF`
class NotificationIds {
  NotificationIds._();

  /// Mask keeping a hash inside a 30-bit range.
  static const int mask30 = 0x3FFFFFFF;

  /// Start of the reserved water range.
  static const int waterBase = 0x40000000;

  /// Id of the "send test notification" notification.
  static const int test = 0x7FFFFFFF;

  /// How many nag ids [NotificationService.cancelSlot] clears when the caller
  /// does not know the nag count that was used at schedule time.
  static const int nagCancelDepth = 5;

  /// 32-bit FNV-1a hash of [input] (as UTF-8 bytes).
  static int fnv1a(String input) {
    var hash = 0x811C9DC5;
    for (final byte in utf8.encode(input)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  /// Id of the first notification for the dose identified by [slotKey].
  static int forDose(String slotKey) => fnv1a(slotKey) & mask30;

  /// Id of nag [n] (1-based) for the dose identified by [slotKey].
  static int nagForDose(String slotKey, int n) => forDose(slotKey) + n;

  /// Id of the water reminder scheduled at [at].
  static int forWater(DateTime at) =>
      waterBase + (fnv1a(WaterPayload(at).encode()) & mask30);
}

/// Called when the user taps a notification or one of its action buttons.
///
/// [actionId] is `null` for a tap on the notification body.
typedef NotificationActionHandler = void Function(
  NotificationPayload payload,
  String? actionId,
);

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// Wraps `flutter_local_notifications` v22 for DoseDrop.
///
/// Platform split (PLAN.md):
/// * **Android** — doses and water are pre-scheduled ~48 h ahead with exact
///   alarms, survive reboot via the plugin's boot receiver, and their action
///   buttons work with the app closed through [doseDropNotificationBackground].
/// * **Linux/Windows** — `zonedSchedule` is not implemented by the desktop
///   backends (it throws `UnimplementedError`), so [rescheduleAll] is a no-op
///   and `DesktopReminderEngine` shows notifications as they come due while the
///   app runs.
class NotificationService {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// True once [init] has completed.
  bool get isReady => _ready;
  bool _ready = false;

  /// True when scheduled (as opposed to live) notifications are supported.
  static bool get supportsScheduling => !kIsWeb && Platform.isAndroid;

  NotificationActionHandler? _handler;

  /// Registers the callback invoked for foreground taps and actions.
  ///
  /// Background actions (app closed) never reach this — they are handled in a
  /// separate isolate by [doseDropNotificationBackground], which writes
  /// straight to storage.
  void setActionHandler(NotificationActionHandler? handler) =>
      _handler = handler;

  /// Alarm-grade channel for doses.
  static const AndroidNotificationChannel doseChannel =
      AndroidNotificationChannel(
    'doses',
    'Medication reminders',
    description: 'Alarm-grade reminders for each scheduled dose.',
    importance: Importance.max,
    playSound: true,
    // The system's default alarm sound, played on the alarm stream.
    sound: UriAndroidNotificationSound('content://settings/system/alarm_alert'),
    audioAttributesUsage: AudioAttributesUsage.alarm,
    enableVibration: true,
    enableLights: true,
  );

  /// Gentler channel for water reminders.
  static const AndroidNotificationChannel waterChannel =
      AndroidNotificationChannel(
    'water',
    'Water reminders',
    description: 'Nudges to drink water during your active hours.',
    importance: Importance.high,
    enableVibration: true,
  );

  /// Initialises the plugin, timezones, channels and permissions.
  ///
  /// Safe to call once at startup; never throws (a device that refuses
  /// notifications must not stop the app from running).
  Future<void> init() async {
    await initTimezones();
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          linux: LinuxInitializationSettings(
            defaultActionName: 'Open DoseDrop',
          ),
          windows: WindowsInitializationSettings(
            appName: 'DoseDrop',
            appUserModelId: 'com.dhivalabs.dose_drop',
            // Stable GUID for the notification activation callback.
            guid: '9f3a1c72-6b4e-4d18-9a5f-2c7e6d0b81aa',
          ),
        ),
        onDidReceiveNotificationResponse: _onForegroundResponse,
        onDidReceiveBackgroundNotificationResponse:
            doseDropNotificationBackground,
      );
      if (!kIsWeb && Platform.isAndroid) {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        await android?.createNotificationChannel(doseChannel);
        await android?.createNotificationChannel(waterChannel);
        await android?.requestNotificationsPermission();
        // Only prompts on Android 14+ when SCHEDULE_EXACT_ALARM is used; the
        // manifest also declares USE_EXACT_ALARM so this is belt and braces.
        await android?.requestExactAlarmsPermission();
      }
      _ready = true;
    } catch (error, stack) {
      debugPrint('NotificationService.init failed: $error\n$stack');
    }
  }

  /// Loads the timezone database and points `tz.local` at the device zone.
  ///
  /// Needed before any `zonedSchedule` call so wall-clock times land on the
  /// intended instant.
  static Future<void> initTimezones() async {
    tz_data.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (error) {
      // Desktop backends may not report a zone; scheduling is Android-only and
      // uses absolute instants, so UTC as `tz.local` stays correct.
      debugPrint('Timezone lookup failed, using ${tz.local.name}: $error');
    }
  }

  void _onForegroundResponse(NotificationResponse response) {
    final payload = NotificationPayload.tryParse(response.payload);
    if (payload == null) return;
    _handler?.call(payload, response.actionId);
  }

  /// The notification the app was launched from, if any.
  Future<({NotificationPayload payload, String? actionId})?>
      launchPayload() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details == null || !details.didNotificationLaunchApp) return null;
      final response = details.notificationResponse;
      final payload = NotificationPayload.tryParse(response?.payload);
      if (payload == null) return null;
      return (payload: payload, actionId: response?.actionId);
    } catch (error) {
      debugPrint('launchPayload failed: $error');
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Details builders
  // -------------------------------------------------------------------------

  static NotificationDetails _doseDetails() => NotificationDetails(
        android: AndroidNotificationDetails(
          doseChannel.id,
          doseChannel.name,
          channelDescription: doseChannel.description,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          audioAttributesUsage: AudioAttributesUsage.alarm,
          sound: doseChannel.sound,
          enableVibration: true,
          // Keep it on screen until the user resolves the dose.
          autoCancel: false,
          ongoing: false,
          actions: const <AndroidNotificationAction>[
            AndroidNotificationAction(kActionTaken, 'Taken'),
            AndroidNotificationAction(kActionSnooze, 'Snooze 10 min'),
            AndroidNotificationAction(kActionSkip, 'Skip'),
          ],
        ),
        linux: const LinuxNotificationDetails(
          urgency: LinuxNotificationUrgency.critical,
          actions: <LinuxNotificationAction>[
            LinuxNotificationAction(key: kActionTaken, label: 'Taken'),
            LinuxNotificationAction(key: kActionSnooze, label: 'Snooze 10 min'),
            LinuxNotificationAction(key: kActionSkip, label: 'Skip'),
          ],
        ),
        windows: const WindowsNotificationDetails(
          actions: <WindowsAction>[
            WindowsAction(content: 'Taken', arguments: kActionTaken),
            WindowsAction(content: 'Snooze 10 min', arguments: kActionSnooze),
            WindowsAction(content: 'Skip', arguments: kActionSkip),
          ],
        ),
      );

  static NotificationDetails _waterDetails(int cupMl) => NotificationDetails(
        android: AndroidNotificationDetails(
          waterChannel.id,
          waterChannel.name,
          channelDescription: waterChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          actions: <AndroidNotificationAction>[
            AndroidNotificationAction(kActionLogWater, 'Log $cupMl ml'),
            const AndroidNotificationAction(kActionDismiss, 'Dismiss'),
          ],
        ),
        linux: LinuxNotificationDetails(
          actions: <LinuxNotificationAction>[
            LinuxNotificationAction(
                key: kActionLogWater, label: 'Log $cupMl ml'),
            const LinuxNotificationAction(
                key: kActionDismiss, label: 'Dismiss'),
          ],
        ),
        windows: WindowsNotificationDetails(
          actions: <WindowsAction>[
            WindowsAction(content: 'Log $cupMl ml', arguments: kActionLogWater),
            const WindowsAction(content: 'Dismiss', arguments: kActionDismiss),
          ],
        ),
      );

  static String doseTitle(Medication med) => 'Time for ${med.name}';

  static String doseBody(DoseSlot slot) {
    final dosage = slot.med.dosage.trim();
    return dosage.isEmpty ? slot.time : '$dosage · ${slot.time}';
  }

  // -------------------------------------------------------------------------
  // Showing now (used by the desktop engine and the test button)
  // -------------------------------------------------------------------------

  /// Shows a dose reminder immediately.
  Future<void> showDose(DoseSlot slot, {int nag = 0}) async {
    final id = nag == 0
        ? NotificationIds.forDose(slot.key)
        : NotificationIds.nagForDose(slot.key, nag);
    await _guard(() => _plugin.show(
          id: id,
          title: nag == 0
              ? doseTitle(slot.med)
              : 'Still waiting: ${slot.med.name}',
          body: doseBody(slot),
          notificationDetails: _doseDetails(),
          payload: DosePayload(slot.key).encode(),
        ));
  }

  /// Shows a water reminder immediately.
  Future<void> showWater(DateTime at, int cupMl) async {
    await _guard(() => _plugin.show(
          id: NotificationIds.forWater(at),
          title: 'Sip time! 💧',
          body: 'Log $cupMl ml to stay on track.',
          notificationDetails: _waterDetails(cupMl),
          payload: WaterPayload(at).encode(),
        ));
  }

  /// Fires a one-off notification so the user can verify reminders work.
  Future<void> sendTestNotification() async {
    await _guard(() => _plugin.show(
          id: NotificationIds.test,
          title: 'DoseDrop is watching your back',
          body: 'This is what a reminder looks like.',
          notificationDetails: _doseDetails(),
        ));
  }

  // -------------------------------------------------------------------------
  // Scheduling (Android)
  // -------------------------------------------------------------------------

  /// How far ahead doses are pre-scheduled on Android.
  static const Duration scheduleHorizon = Duration(hours: 48);

  /// Rebuilds the whole Android schedule from [data].
  ///
  /// Cancels everything, then schedules each unresolved dose in the next 48 h
  /// (plus its nags) and every water slot in that window. Past times, resolved
  /// doses and everything inside a [AppSettings.pausedUntil] window are
  /// skipped. No-op off Android — desktop reminders come from
  /// `DesktopReminderEngine`.
  Future<void> rescheduleAll(AppData data, {DateTime? now}) async {
    if (!supportsScheduling) return;
    final from = now ?? DateTime.now();
    final until = from.add(scheduleHorizon);
    final settings = data.settings;
    final pausedUntil = settings.pausedUntil;

    bool isSuppressed(DateTime at) =>
        !at.isAfter(from) ||
        at.isAfter(until) ||
        (pausedUntil != null && at.isBefore(pausedUntil));

    await _guard(_plugin.cancelAll);

    for (var offset = 0; offset <= scheduleHorizon.inHours ~/ 24 + 1; offset++) {
      final day = Days.add(from, offset);
      for (final slot in ScheduleEngine.slotsForDay(data.meds, day)) {
        final record = data.records[slot.key];
        if (record != null && record.status.isActed) continue;
        final due = ScheduleEngine.effectiveDue(slot, record);
        final graceEnd = due.add(settings.grace);
        if (!isSuppressed(due)) {
          await _scheduleDose(slot, due, id: NotificationIds.forDose(slot.key));
        }
        var nag = 0;
        for (final nagAt in ScheduleEngine.nagTimes(due, settings)) {
          nag++;
          // A dose is auto-missed at due + grace; nagging past that is noise.
          if (!nagAt.isBefore(graceEnd) || isSuppressed(nagAt)) continue;
          await _scheduleDose(slot, nagAt,
              id: NotificationIds.nagForDose(slot.key, nag), nag: nag);
        }
      }
      for (final at
          in ScheduleEngine.waterSlotsForDay(data.waterSettings, day)) {
        if (isSuppressed(at)) continue;
        await _scheduleWater(at, data.waterSettings.cupMl);
      }
    }
  }

  Future<void> _scheduleDose(
    DoseSlot slot,
    DateTime at, {
    required int id,
    int nag = 0,
  }) async {
    await _guard(() => _plugin.zonedSchedule(
          id: id,
          title:
              nag == 0 ? doseTitle(slot.med) : 'Still waiting: ${slot.med.name}',
          body: doseBody(slot),
          scheduledDate: tz.TZDateTime.from(at, tz.local),
          notificationDetails: _doseDetails(),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          payload: DosePayload(slot.key).encode(),
        ));
  }

  Future<void> _scheduleWater(DateTime at, int cupMl) async {
    await _guard(() => _plugin.zonedSchedule(
          id: NotificationIds.forWater(at),
          title: 'Sip time! 💧',
          body: 'Log $cupMl ml to stay on track.',
          scheduledDate: tz.TZDateTime.from(at, tz.local),
          notificationDetails: _waterDetails(cupMl),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          payload: WaterPayload(at).encode(),
        ));
  }

  // -------------------------------------------------------------------------
  // Cancelling
  // -------------------------------------------------------------------------

  /// Cancels the notification for [slotKey] and all of its nags.
  Future<void> cancelSlot(
    String slotKey, {
    int nagCount = NotificationIds.nagCancelDepth,
  }) async {
    await _guard(() => cancelSlotWith(_plugin, slotKey, nagCount: nagCount));
  }

  /// Cancels a water reminder.
  Future<void> cancelWater(DateTime at) async {
    await _guard(() => _plugin.cancel(id: NotificationIds.forWater(at)));
  }

  /// Cancels everything currently shown or scheduled.
  Future<void> cancelAll() async => _guard(_plugin.cancelAll);

  /// Shared by the app and the background isolate: clears a slot's first
  /// notification plus [nagCount] nag ids.
  static Future<void> cancelSlotWith(
    FlutterLocalNotificationsPlugin plugin,
    String slotKey, {
    int nagCount = NotificationIds.nagCancelDepth,
  }) async {
    final base = NotificationIds.forDose(slotKey);
    for (var n = 0; n <= nagCount; n++) {
      await plugin.cancel(id: base + n);
    }
  }

  /// Runs [action], swallowing platform failures.
  ///
  /// A phone that denies notifications, a desktop without a notification
  /// daemon, or a missing plugin in a background isolate must degrade quietly
  /// rather than break a user action.
  static Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      debugPrint('NotificationService: $error');
    }
  }
}

// ---------------------------------------------------------------------------
// Background isolate
// ---------------------------------------------------------------------------

/// Handles a notification action while the app is closed.
///
/// Android runs this in a **separate isolate** with its own Flutter engine, so
/// there is no `AppState` and no UI: the handler edits the JSON store directly
/// through [StorageService]'s static API and then clears the slot's nags.
///
/// Must stay a top-level `@pragma('vm:entry-point')` function or the compiler
/// strips it and the plugin cannot look up its handle.
@pragma('vm:entry-point')
void doseDropNotificationBackground(NotificationResponse response) {
  // The callback signature is synchronous; the engine stays alive while the
  // future completes.
  unawaited(applyNotificationAction(response));
}

/// Applies [response] to persisted state. Used by the background isolate and
/// unit-testable on its own.
Future<void> applyNotificationAction(
  NotificationResponse response, {
  String? dataDirPath,
  FlutterLocalNotificationsPlugin? plugin,
}) async {
  final payload = NotificationPayload.tryParse(response.payload);
  final actionId = response.actionId;
  if (payload == null || actionId == null || actionId == kActionDismiss) return;

  final dir = dataDirPath ?? await resolveBackgroundDataDir();
  if (dir == null) {
    debugPrint('Background action: could not resolve the data directory');
    return;
  }

  final now = DateTime.now();
  final data = await StorageService.loadFrom(dir);
  final result = applyActionToData(data, payload, actionId, now);
  if (result == null) return;
  await StorageService.saveTo(dir, result.data);

  final notifications = plugin ?? FlutterLocalNotificationsPlugin();
  switch (payload) {
    case DosePayload(:final slotKey):
      await NotificationService._guard(
        () => NotificationService.cancelSlotWith(notifications, slotKey),
      );
      final snoozedUntil = result.snoozedUntil;
      if (snoozedUntil != null) {
        await _scheduleSnoozeFromBackground(
          notifications,
          data,
          slotKey,
          snoozedUntil,
        );
      }
    case WaterPayload(:final at):
      await NotificationService._guard(
        () => notifications.cancel(id: NotificationIds.forWater(at)),
      );
  }
}

/// Outcome of applying a notification action to [AppData].
typedef ActionResult = ({AppData data, DateTime? snoozedUntil});

/// Pure state transition for a notification action — no I/O, so it is testable.
///
/// Returns `null` when the action is a no-op (unknown action, or a dose that
/// was already resolved elsewhere).
ActionResult? applyActionToData(
  AppData data,
  NotificationPayload payload,
  String actionId,
  DateTime now,
) {
  switch (payload) {
    case WaterPayload():
      if (actionId != kActionLogWater) return null;
      return (
        data: data.copyWith(
          water: <WaterEntry>[
            ...data.water,
            WaterEntry(at: now, ml: data.waterSettings.cupMl),
          ],
        ),
        snoozedUntil: null,
      );

    case DosePayload(:final slotKey):
      final existing = data.records[slotKey];
      if (existing != null && existing.status.isActed) return null;
      final DoseRecord updated;
      DateTime? snoozedUntil;
      switch (actionId) {
        case kActionTaken:
          updated = DoseRecord(
            key: slotKey,
            status: DoseStatus.taken,
            actedAt: now,
          );
        case kActionSkip:
          updated = DoseRecord(
            key: slotKey,
            status: DoseStatus.skipped,
            actedAt: now,
          );
        case kActionSnooze:
          snoozedUntil = now.add(Duration(minutes: AppSettings.snoozeMinutes));
          updated = DoseRecord(
            key: slotKey,
            snoozedUntil: snoozedUntil,
          );
        default:
          return null;
      }
      return (
        data: data.copyWith(records: <String, DoseRecord>{
          ...data.records,
          slotKey: updated,
        }),
        snoozedUntil: snoozedUntil,
      );
  }
}

Future<void> _scheduleSnoozeFromBackground(
  FlutterLocalNotificationsPlugin plugin,
  AppData data,
  String slotKey,
  DateTime at,
) async {
  final parts = DoseKey.tryParse(slotKey);
  final med = parts == null ? null : data.medById(parts.medId);
  await NotificationService._guard(() async {
    tz_data.initializeTimeZones();
    await plugin.zonedSchedule(
      id: NotificationIds.forDose(slotKey),
      title: med == null ? 'Time for your dose' : 'Time for ${med.name}',
      body: med == null || med.dosage.isEmpty
          ? 'Snoozed reminder'
          : '${med.dosage} · snoozed reminder',
      // `at` is an absolute instant, so expressing it in UTC schedules exactly
      // the same moment without needing the device zone (flutter_timezone is a
      // plugin and may be unavailable in this isolate).
      scheduledDate: tz.TZDateTime.from(at, tz.UTC),
      notificationDetails: NotificationService._doseDetails(),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: DosePayload(slotKey).encode(),
    );
  });
}

/// Best-effort lookup of the app's data directory from a background isolate.
///
/// The plugin's `ActionBroadcastReceiver` spins up a bare `FlutterEngine`. Newer
/// Android embeddings auto-register plugins on it, in which case `path_provider`
/// works — but that is not guaranteed, and a `MissingPluginException` here would
/// silently lose the user's tap. So this tries, in order:
///
/// 1. `path_provider`'s application support directory (the normal path);
/// 2. the sibling of the process temp dir — Android points `TMPDIR` at
///    `<data>/cache`, whose sibling `<data>/files` is exactly what
///    `getApplicationSupportDirectory()` returns;
/// 3. `/data/user/0/<package>/files` (and the `/data/data` alias), with the
///    package name read from `/proc/self/cmdline`.
///
/// Returns `null` when nothing checks out, in which case the caller gives up
/// rather than writing state to the wrong place.
Future<String?> resolveBackgroundDataDir() async {
  try {
    return (await getApplicationSupportDirectory()).path;
  } catch (error) {
    debugPrint('path_provider unavailable in background isolate: $error');
  }
  return androidDataDirFallback();
}

/// Plugin-free guesses for the Android app data directory, first hit wins.
@visibleForTesting
String? androidDataDirFallback() {
  if (kIsWeb || !Platform.isAndroid) return null;
  final candidates = <String>[];

  try {
    final temp = Directory.systemTemp.path;
    if (temp.startsWith('/data/')) {
      candidates.add('${File(temp).parent.path}/files');
    }
  } catch (_) {
    // systemTemp can throw when TMPDIR points nowhere useful.
  }

  final package = _packageNameFromProc();
  if (package != null) {
    candidates.add('/data/user/0/$package/files');
    candidates.add('/data/data/$package/files');
  }

  for (final candidate in candidates) {
    try {
      if (Directory(candidate).existsSync()) return candidate;
    } catch (_) {
      // Unreadable candidate: try the next one.
    }
  }
  return null;
}

String? _packageNameFromProc() {
  try {
    final raw = File('/proc/self/cmdline').readAsStringSync();
    // cmdline is NUL-delimited; the first entry is the process name, which for
    // an Android app is its package (optionally with a `:process` suffix).
    final first = raw.split('\u0000').first.split(':').first.trim();
    return first.isEmpty ? null : first;
  } catch (_) {
    return null;
  }
}
