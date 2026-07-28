import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'notification_service.dart';
import 'schedule_engine.dart';

/// What kind of reminder a [ReminderFire] is about.
enum ReminderKind { dose, water }

/// One alerting moment: a dose (or water slot) reaching its due time or one of
/// its nag times.
class ReminderFire {
  const ReminderFire({
    required this.kind,
    required this.at,
    this.slot,
    this.nag = 0,
  });

  final ReminderKind kind;

  /// The instant this alert belongs to — the due time, or the nag time.
  final DateTime at;

  /// The dose, for [ReminderKind.dose].
  final DoseSlot? slot;

  /// 0 for the first alert, 1..n for escalating nags.
  final int nag;

  /// Stable identity of this exact alerting moment, used to fire it only once.
  String get dedupeKey => switch (kind) {
        ReminderKind.dose => 'dose#${slot?.key}#${at.toIso8601String()}',
        ReminderKind.water => 'water#${at.toIso8601String()}',
      };

  @override
  String toString() => 'ReminderFire(${kind.name}, at: $at, nag: $nag, '
      'slot: ${slot?.key})';
}

/// What a tick should do: [fire] these alerts, and mark [swallow] as seen
/// without alerting.
///
/// Swallowing is what stops a burst: if the app was asleep (or paused) over
/// several nag points, only the most recent one alerts and the stale ones are
/// recorded so they never fire later.
typedef ReminderTick = ({List<ReminderFire> fire, List<String> swallow});

/// Pure decision logic for desktop reminders — no timers, no I/O, no Flutter.
class ReminderPlanner {
  ReminderPlanner._();

  /// How late a water reminder may still be shown after its slot time.
  static const Duration waterCatchUp = Duration(minutes: 15);

  /// Works out what to alert about at [now].
  ///
  /// [seen] holds the [ReminderFire.dedupeKey]s already handled. While
  /// reminders are paused ([AppSettings.pausedUntil]) everything due is
  /// swallowed, so the pause ends quietly instead of with a backlog.
  static ReminderTick plan({
    required AppData data,
    required DateTime now,
    required Set<String> seen,
    Duration waterCatchUp = ReminderPlanner.waterCatchUp,
  }) {
    final fire = <ReminderFire>[];
    final swallow = <String>[];
    final paused = data.settings.isPausedAt(now);

    void consider(List<ReminderFire> points, {required bool allowFire}) {
      if (points.isEmpty) return;
      // Points are ordered oldest first; only the last one may alert.
      for (var i = 0; i < points.length; i++) {
        final point = points[i];
        if (seen.contains(point.dedupeKey)) continue;
        final isLatest = i == points.length - 1;
        if (isLatest && allowFire && !paused) {
          fire.add(point);
        } else {
          swallow.add(point.dedupeKey);
        }
      }
    }

    // --- Doses: the due point plus every nag point that has arrived. --------
    final due = ScheduleEngine.dueNow(
      data.meds,
      data.records,
      now,
      data.settings.grace,
    );
    for (final slot in due) {
      final record = data.records[slot.key];
      final effectiveDue = ScheduleEngine.effectiveDue(slot, record);
      final points = <ReminderFire>[
        ReminderFire(kind: ReminderKind.dose, slot: slot, at: effectiveDue),
        for (final (index, nagAt)
            in ScheduleEngine.nagTimes(effectiveDue, data.settings).indexed)
          ReminderFire(
            kind: ReminderKind.dose,
            slot: slot,
            at: nagAt,
            nag: index + 1,
          ),
      ].where((point) => !point.at.isAfter(now)).toList();
      consider(points, allowFire: true);
    }

    // --- Water: today's slots, only recent ones are worth showing. ----------
    final waterPoints = <ReminderFire>[
      for (final at
          in ScheduleEngine.waterSlotsForDay(data.waterSettings, now))
        if (!at.isAfter(now)) ReminderFire(kind: ReminderKind.water, at: at),
    ];
    if (waterPoints.isNotEmpty) {
      final latest = waterPoints.last;
      final isFresh = now.difference(latest.at) <= waterCatchUp;
      consider(waterPoints, allowFire: isFresh);
    }

    return (fire: fire, swallow: swallow);
  }
}

/// Fires reminders on Linux/Windows, where the plugin cannot schedule anything.
///
/// A 15-second timer asks [ReminderPlanner] what is due, shows the desktop
/// notification and hands the alert to [onFire] (which is how `AppState` raises
/// the in-app alarm overlay and starts the alarm sound).
///
/// Each due/nag moment fires exactly once, even across pauses, app sleep or a
/// user changing the nag settings mid-dose.
class DesktopReminderEngine {
  DesktopReminderEngine({
    required this._notifications,
    required this._snapshot,
    required this._onFire,
    this._interval = const Duration(seconds: 15),
  });

  final NotificationService _notifications;
  final AppData Function() _snapshot;
  final void Function(ReminderFire fire) _onFire;
  final Duration _interval;

  /// Dedupe memory: fire key -> the instant it belonged to (used for pruning).
  final Map<String, DateTime> _seen = <String, DateTime>{};

  Timer? _timer;

  /// True on the platforms that need this engine at all.
  static bool get isSupported =>
      !kIsWeb && (Platform.isLinux || Platform.isWindows);

  bool get isRunning => _timer != null;

  /// Keys already handled — exposed for diagnostics and tests.
  @visibleForTesting
  Set<String> get seenKeys => _seen.keys.toSet();

  /// Starts ticking. No-op on Android (scheduled notifications cover it).
  void start() {
    if (!isSupported || _timer != null) return;
    _timer = Timer.periodic(_interval, (_) => tick());
    tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => stop();

  /// Runs one pass. Called by the timer, or directly from tests.
  void tick([DateTime? at]) {
    final now = at ?? DateTime.now();
    final data = _snapshot();
    final plan = ReminderPlanner.plan(data: data, now: now, seen: seenKeys);

    for (final key in plan.swallow) {
      _seen[key] = now;
    }
    for (final fire in plan.fire) {
      _seen[fire.dedupeKey] = fire.at;
      _show(fire, data);
      _onFire(fire);
    }
    _prune(now);
  }

  /// Forgets a slot's fire history so a re-snoozed dose can alert again.
  void forgetSlot(String slotKey) =>
      _seen.removeWhere((key, _) => key.startsWith('dose#$slotKey#'));

  void _show(ReminderFire fire, AppData data) {
    switch (fire.kind) {
      case ReminderKind.dose:
        final slot = fire.slot;
        if (slot != null) {
          unawaited(_notifications.showDose(slot, nag: fire.nag));
        }
      case ReminderKind.water:
        unawaited(
          _notifications.showWater(fire.at, data.waterSettings.cupMl),
        );
    }
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(const Duration(days: 2));
    _seen.removeWhere((_, at) => at.isBefore(cutoff));
  }
}
