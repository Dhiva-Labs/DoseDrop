import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/alarm_sound.dart';
import 'services/app_state.dart';
import 'services/notification_service.dart';
import 'services/storage_service.dart';
import 'services/tray_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The whole app state lives in one JSON file here; the directory is injected
  // into StorageService so it stays testable and isolate-friendly.
  final supportDir = await getApplicationSupportDirectory();

  final notifications = NotificationService();
  await notifications.init();

  final state = AppState(
    storage: StorageService(supportDir),
    notifications: notifications,
    alarmSound: AlarmSound(supportDir: supportDir),
  );

  TrayService? tray;
  if (TrayService.isSupported) {
    await windowManager.ensureInitialized();
    tray = TrayService(
      // Coming back from the tray is a good moment to pick up anything written
      // while the window was hidden.
      onOpen: state.syncFromDisk,
      onPause: () => state.pauseReminders(),
      onQuit: state.flush,
    );
    state.attachTray(tray);
    await tray.initWindow();
    await tray.initTray();
  }

  await state.load();
  await state.handleLaunch();

  runApp(ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const DoseDropApp(),
  ));
}
