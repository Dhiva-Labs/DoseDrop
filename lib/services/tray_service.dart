import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Keeps DoseDrop alive in the desktop tray so reminders can still fire after
/// the window is closed.
///
/// Linux/Windows only — every entry point is a no-op elsewhere. Closing the
/// window hides it (the process keeps running); quitting is only possible from
/// the tray menu, which is what makes the timer-based
/// `DesktopReminderEngine` useful at all.
class TrayService with TrayListener, WindowListener {
  TrayService({
    required this.onOpen,
    required this.onPause,
    required this.onQuit,
  });

  /// "Open DoseDrop" — also the tray icon click action.
  final VoidCallback onOpen;

  /// "Pause 1 hour" — `AppState.pauseReminders`.
  final VoidCallback onPause;

  /// "Quit" — flush state, then [destroy].
  final Future<void> Function() onQuit;

  /// Tray icon generated into the assets (teal droplet, see
  /// tools/generate_tray_icon.py). Windows needs the .ico: tray_manager loads
  /// it with LoadImage(IMAGE_ICON), which cannot read a PNG and would leave
  /// an empty slot in the notification area.
  static String get iconPath =>
      Platform.isWindows ? 'assets/icon/tray.ico' : 'assets/icon/tray.png';

  /// Default window geometry (DESIGN.md).
  static const Size windowSize = Size(1100, 720);
  static const Size minWindowSize = Size(900, 600);

  static const String _keyOpen = 'open';
  static const String _keyPause = 'pause';
  static const String _keyQuit = 'quit';

  /// True on the platforms with a tray and a resizable window.
  static bool get isSupported =>
      !kIsWeb && (Platform.isLinux || Platform.isWindows);

  bool _windowReady = false;

  /// Prepares the window: size, minimum size, title, close-to-tray.
  ///
  /// Call after `windowManager.ensureInitialized()` and before `runApp`.
  Future<void> initWindow() async {
    if (!isSupported) return;
    try {
      windowManager.addListener(this);
      const options = WindowOptions(
        size: windowSize,
        minimumSize: minWindowSize,
        center: true,
        title: 'DoseDrop',
      );
      await windowManager.waitUntilReadyToShow(options, () async {
        await windowManager.show();
        await windowManager.focus();
      });
      // Intercept the X button so the app survives in the tray.
      await windowManager.setPreventClose(true);
      _windowReady = true;
    } catch (error) {
      debugPrint('TrayService.initWindow failed: $error');
    }
  }

  /// Installs the tray icon and its menu.
  Future<void> initTray() async {
    if (!isSupported) return;
    try {
      trayManager.addListener(this);
      await trayManager.setIcon(_trayIcon);
      try {
        await trayManager.setToolTip(
          'DoseDrop — your tablets & water, on time.',
        );
      } catch (error) {
        // The Linux AppIndicator backend has no tooltip and answers with
        // MissingPluginException. That must not skip the menu below, which is
        // the only way back to a window that was closed to the tray.
        debugPrint('TrayService: tooltip not supported: $error');
      }
      await _applyMenu();
    } catch (error) {
      // A desktop with no system tray must not stop the app from running.
      debugPrint('TrayService.initTray failed: $error');
    }
  }

  /// The icon argument for `trayManager.setIcon`.
  ///
  /// Inside a sandbox (snap, Flatpak) tray_manager passes the argument to the
  /// AppIndicator verbatim instead of resolving it against the bundle, so the
  /// desktop shell would be asked for an icon literally named
  /// `assets/icon/tray.png`. An absolute path works both there and in a plain
  /// install, where tray_manager's own join leaves an absolute path alone.
  static String get _trayIcon => Platform.isLinux
      ? '${File(Platform.resolvedExecutable).parent.path}'
            '/data/flutter_assets/$iconPath'
      : iconPath;

  Future<void> _applyMenu() async {
    await trayManager.setContextMenu(Menu(items: <MenuItem>[
      MenuItem(key: _keyOpen, label: 'Open DoseDrop'),
      MenuItem(key: _keyPause, label: 'Pause 1 hour'),
      MenuItem.separator(),
      MenuItem(key: _keyQuit, label: 'Quit'),
    ]));
  }

  /// Brings the window back from the tray.
  Future<void> showWindow() async {
    if (!isSupported || !_windowReady) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (error) {
      debugPrint('TrayService.showWindow failed: $error');
    }
  }

  /// Hides the window, leaving the process (and reminders) running.
  Future<void> hideWindow() async {
    if (!isSupported || !_windowReady) return;
    try {
      await windowManager.hide();
    } catch (error) {
      debugPrint('TrayService.hideWindow failed: $error');
    }
  }

  /// Really quits: removes the tray icon and tears the window down.
  Future<void> destroy() async {
    if (!isSupported) return;
    try {
      await trayManager.destroy();
    } catch (error) {
      debugPrint('TrayService.destroy (tray) failed: $error');
    }
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (error) {
      debugPrint('TrayService.destroy (window) failed: $error');
    }
  }

  /// Detaches listeners. Does not quit the app.
  void dispose() {
    if (!isSupported) return;
    trayManager.removeListener(this);
    windowManager.removeListener(this);
  }

  // -------------------------------------------------------------------------
  // Listeners
  // -------------------------------------------------------------------------

  @override
  void onWindowClose() {
    // preventClose is on, so this is the X button: hide instead of exiting.
    unawaited(hideWindow());
  }

  @override
  void onTrayIconMouseDown() {
    onOpen();
    unawaited(showWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _keyOpen:
        onOpen();
        unawaited(showWindow());
      case _keyPause:
        onPause();
      case _keyQuit:
        unawaited(_quit());
    }
  }

  Future<void> _quit() async {
    await onQuit();
    await destroy();
  }
}

/// Desktop "launch at login", driven by `AppSettings.autostart`.
///
/// Linux and unpackaged Windows builds register through launch_at_startup
/// (an autostart .desktop file, the HKCU Run key). The Microsoft Store build
/// is an MSIX package, where that Run key is virtualized and never seen by
/// Windows; it declares a startup task instead (msix_config.startup_task in
/// pubspec.yaml), switched through the runner's `dosedrop/startup_task`
/// channel (windows/runner/startup_task.cpp). Windows then owns the switch:
/// the user can also flip it in Settings > Apps > Startup.
///
/// Silent no-op on mobile and on desktops where the registration fails (a
/// read-only autostart directory, a sandbox, …) — the setting simply won't
/// stick, which is better than crashing on a preference toggle.
class AutostartService {
  AutostartService._();

  static bool _configured = false;

  static const MethodChannel _startupTask = MethodChannel(
    'dosedrop/startup_task',
  );

  /// True once the runner has reported a packaged (MSIX) install, where
  /// Windows owns the setting. Known after the first [systemState] or
  /// [apply] call.
  static bool systemManaged = false;

  static bool get isSupported =>
      !kIsWeb && (Platform.isLinux || Platform.isWindows);

  /// Registers the app identity with the plugin. Safe to call repeatedly.
  static void configure() {
    if (!isSupported || _configured) return;
    launchAtStartup.setup(
      appName: 'DoseDrop',
      appPath: Platform.resolvedExecutable,
      packageName: 'com.dhivalabs.dose_drop',
    );
    _configured = true;
  }

  /// Calls the runner's startup task bridge. Returns the task state, or null
  /// when this is not a packaged Windows build.
  static Future<String?> _callStartupTask(String method) async {
    if (kIsWeb || !Platform.isWindows) return null;
    try {
      final state = await _startupTask.invokeMethod<String>(method);
      if (state == null || state == 'unpackaged') return null;
      systemManaged = true;
      return state;
    } on PlatformException catch (error) {
      // Packaged, but the WinRT call failed: report "off" rather than
      // falling back to the (virtualized, useless) Run key.
      systemManaged = true;
      debugPrint('AutostartService: startup task $method failed: $error');
      return 'error';
    } on MissingPluginException {
      return null;
    }
  }

  static bool _isOn(String state) =>
      state == 'enabled' || state == 'enabledByPolicy';

  /// Whether Windows will start DoseDrop at login, for a packaged (Store)
  /// install; null everywhere else, where the app's own setting is the
  /// source of truth.
  static Future<bool?> systemState() async {
    if (!isSupported) return null;
    final state = await _callStartupTask('getState');
    return state == null ? null : _isOn(state);
  }

  /// Enables or disables launching DoseDrop at login. Returns whether it is
  /// enabled afterwards; on a packaged install Windows can refuse (the user
  /// switched DoseDrop off in Settings > Apps > Startup, or a policy).
  static Future<bool> apply({required bool enabled}) async {
    if (!isSupported) return false;
    final state = await _callStartupTask(enabled ? 'enable' : 'disable');
    if (state != null) return _isOn(state);
    configure();
    try {
      if (enabled) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
    } catch (error) {
      debugPrint('AutostartService.apply($enabled) failed: $error');
    }
    return enabled;
  }

  /// Whether the OS currently has DoseDrop registered for login.
  static Future<bool> isEnabled() async {
    if (!isSupported) return false;
    final system = await systemState();
    if (system != null) return system;
    configure();
    try {
      return await launchAtStartup.isEnabled();
    } catch (error) {
      debugPrint('AutostartService.isEnabled failed: $error');
      return false;
    }
  }
}
