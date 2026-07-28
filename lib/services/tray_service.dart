import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
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

  /// Tray icon generated into the assets (64×64 teal droplet).
  static const String iconPath = 'assets/icon/tray.png';

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
      await trayManager.setIcon(iconPath);
      await trayManager.setToolTip('DoseDrop — your tablets & water, on time.');
      await _applyMenu();
    } catch (error) {
      // A desktop with no system tray must not stop the app from running.
      debugPrint('TrayService.initTray failed: $error');
    }
  }

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
/// Silent no-op on mobile and on desktops where the registration fails (a
/// read-only autostart directory, a sandbox, …) — the setting simply won't
/// stick, which is better than crashing on a preference toggle.
class AutostartService {
  AutostartService._();

  static bool _configured = false;

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

  /// Enables or disables launching DoseDrop at login.
  static Future<void> apply({required bool enabled}) async {
    if (!isSupported) return;
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
  }

  /// Whether the OS currently has DoseDrop registered for login.
  static Future<bool> isEnabled() async {
    if (!isSupported) return false;
    configure();
    try {
      return await launchAtStartup.isEnabled();
    } catch (error) {
      debugPrint('AutostartService.isEnabled failed: $error');
      return false;
    }
  }
}
