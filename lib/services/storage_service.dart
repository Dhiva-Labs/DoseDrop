import 'dart:convert';
import 'dart:io';

import '../models/models.dart';

/// JSON persistence for [AppData].
///
/// The whole app state lives in a single file, `<dir>/dose_drop_data.json`,
/// written atomically (`.tmp` + rename) so a crash or a kill mid-write can never
/// leave a half-written file behind.
///
/// Two ways in:
/// * **Instance API** — `StorageService(dir).load()` / `.save(data)`, used by
///   `AppState`. The directory is injected (never resolved with `path_provider`
///   here) so tests can point it at a temp dir.
/// * **Static raw API** — [loadFrom] / [saveTo] take a plain directory path and
///   need no Flutter bindings, which is what the Android background
///   notification-action isolate uses (it cannot reach `AppState`).
///
/// Reads never throw: a missing, empty, truncated or corrupt file yields
/// [AppData.empty] so a bad file can't brick the app.
class StorageService {
  static const String fileName = 'dose_drop_data.json';
  static const String tmpSuffix = '.tmp';

  /// Directory the data file lives in (injected — see class docs).
  final Directory dir;

  StorageService(this.dir);

  /// Absolute path of the data file.
  String get filePath => pathFor(dir.path);

  /// The data file itself (may not exist yet).
  File get file => File(filePath);

  /// Loads persisted state, falling back to [AppData.empty].
  Future<AppData> load() => loadFrom(dir.path);

  /// Atomically persists [data].
  Future<void> save(AppData data) => saveTo(dir.path, data);

  /// Deletes the data file, if present. Used by "reset app data".
  Future<void> clear() async {
    final target = file;
    if (await target.exists()) await target.delete();
  }

  /// When the data file was last written, or `null` if it does not exist.
  ///
  /// Lets the app notice writes made by the Android background isolate while it
  /// was running — see `AppState.syncFromDisk`.
  Future<DateTime?> lastModified() async {
    try {
      final target = file;
      if (!await target.exists()) return null;
      return await target.lastModified();
    } catch (_) {
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Static raw API — safe from a background isolate (no Flutter bindings).
  // -------------------------------------------------------------------------

  /// Path of the data file inside [dirPath].
  static String pathFor(String dirPath) {
    final sep = Platform.pathSeparator;
    final base = dirPath.endsWith(sep) || dirPath.endsWith('/')
        ? dirPath.substring(0, dirPath.length - 1)
        : dirPath;
    return '$base$sep$fileName';
  }

  /// Reads [AppData] from `<dirPath>/dose_drop_data.json`.
  ///
  /// Never throws: anything unreadable or unparseable yields [AppData.empty].
  static Future<AppData> loadFrom(String dirPath) async {
    try {
      final target = File(pathFor(dirPath));
      if (!await target.exists()) return AppData.empty;
      final text = await target.readAsString();
      if (text.trim().isEmpty) return AppData.empty;
      final decoded = jsonDecode(text);
      if (decoded is! Map) return AppData.empty;
      return AppData.fromJson(
        decoded.map((k, v) => MapEntry<String, dynamic>(k.toString(), v)),
      );
    } catch (_) {
      // Corrupt/unreadable file: start clean rather than crash the app.
      return AppData.empty;
    }
  }

  /// Writes [data] to `<dirPath>/dose_drop_data.json` atomically.
  ///
  /// The payload goes to a sibling `.tmp` file first and is only then renamed
  /// over the target, so readers see either the old or the new file — never a
  /// partial one. The `.tmp` file is always cleaned up.
  static Future<void> saveTo(String dirPath, AppData data) async {
    final target = File(pathFor(dirPath));
    final tmp = File('${target.path}$tmpSuffix');
    await target.parent.create(recursive: true);
    try {
      await tmp.writeAsString(jsonEncode(data.toJson()), flush: true);
      try {
        await tmp.rename(target.path);
      } on FileSystemException {
        // Some platforms refuse to rename onto an existing file.
        if (await target.exists()) await target.delete();
        await tmp.rename(target.path);
      }
    } finally {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {
          // Best effort: a stale .tmp is harmless, it is overwritten next save.
        }
      }
    }
  }
}
