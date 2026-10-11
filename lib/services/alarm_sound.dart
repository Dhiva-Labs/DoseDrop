import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Loops the bundled alarm while a desktop reminder is ringing.
///
/// Desktop only. On Android the notification channel carries the alarm sound
/// (see `NotificationService.doseChannel`), so every method here is a no-op.
///
/// Why a subprocess: this machine has no working `media_kit`/gstreamer stack
/// (PLAN.md), so the sound is played by re-spawning a system player and killing
/// it to stop:
/// * **Linux** — `aplay` (present at `/usr/bin/aplay`), one process per loop.
/// * **Windows** — PowerShell's `Media.SoundPlayer` (best effort).
///
/// A missing player, an unreadable asset or a refused spawn is never fatal: the
/// alarm simply stays silent and the visual overlay still nags.
class AlarmSound {
  AlarmSound({required this.supportDir, this.maxDuration = _defaultMaxDuration});

  /// Where the wav is materialised so a system player can read it.
  final Directory supportDir;

  /// Safety stop: an unattended alarm gives up after this long instead of
  /// looping forever. Nags re-trigger it if the dose is still unresolved.
  final Duration maxDuration;

  static const Duration _defaultMaxDuration = Duration(minutes: 2);

  /// Asset bundled by pubspec.
  static const String assetPath = 'assets/sounds/alarm.wav';

  /// File name used inside [supportDir].
  static const String fileName = 'alarm.wav';

  /// True on platforms where this class actually plays anything.
  static bool get isSupported =>
      !kIsWeb && (Platform.isLinux || Platform.isWindows);

  bool get isPlaying => _looping;
  bool _looping = false;

  Process? _process;
  Timer? _stopTimer;
  File? _wav;

  /// Copies the asset out of the bundle so a player can reach it.
  ///
  /// Cheap and idempotent: it only rewrites the file when it is missing or a
  /// different size (i.e. after an app update).
  Future<void> prepare() async {
    if (!isSupported) return;
    try {
      final target = File('${supportDir.path}${Platform.pathSeparator}$fileName');
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();
      final exists = await target.exists();
      if (!exists || await target.length() != bytes.length) {
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes, flush: true);
      }
      _wav = target;
    } catch (error) {
      debugPrint('AlarmSound.prepare failed: $error');
      _wav = null;
    }
  }

  /// Starts looping the alarm. Does nothing if it is already playing.
  Future<void> startLoop() async {
    if (!isSupported || _looping) return;
    if (_wav == null) await prepare();
    final wav = _wav;
    if (wav == null || !await wav.exists()) return;
    _looping = true;
    _stopTimer?.cancel();
    _stopTimer = Timer(maxDuration, stop);
    await _playOnce(wav);
  }

  /// Stops the alarm and kills the player.
  Future<void> stop() async {
    _looping = false;
    _stopTimer?.cancel();
    _stopTimer = null;
    final process = _process;
    _process = null;
    if (process == null) return;
    try {
      process.kill();
    } catch (error) {
      debugPrint('AlarmSound.stop failed: $error');
    }
  }

  /// Releases resources. The sound cannot be restarted after this.
  Future<void> dispose() => stop();

  Future<void> _playOnce(File wav) async {
    try {
      final process = Platform.isWindows
          ? await Process.start('powershell', <String>[
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              // A ' in the path (a user name like O'Neil) is doubled for
              // the single-quoted PowerShell string.
              "(New-Object Media.SoundPlayer "
                  "'${wav.path.replaceAll("'", "''")}').PlaySync()",
            ])
          : await Process.start('aplay', <String>['-q', wav.path]);
      _process = process;
      // Re-spawn when the clip ends, which is how the loop is implemented.
      unawaited(process.exitCode.then((_) {
        if (_process == process) _process = null;
        if (_looping) _playOnce(wav);
      }));
    } catch (error) {
      // No player on this box: give up quietly rather than retry in a hot loop.
      debugPrint('AlarmSound: cannot play ${wav.path}: $error');
      _looping = false;
      _stopTimer?.cancel();
      _stopTimer = null;
    }
  }
}
