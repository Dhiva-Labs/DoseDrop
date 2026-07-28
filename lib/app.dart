import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/models.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/meds_screen.dart';
import 'screens/water_screen.dart';
import 'services/app_state.dart';
import 'theme/app_theme.dart';
import 'widgets/alarm_overlay.dart';

class DoseDropApp extends StatelessWidget {
  const DoseDropApp({super.key});

  /// Maps our Flutter-free preference onto Flutter's [ThemeMode].
  static ThemeMode themeModeOf(AppThemeMode mode) => switch (mode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      };

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppState, AppThemeMode>(
      (state) => state.settings.themeMode,
    );
    return MaterialApp(
      title: 'DoseDrop',
      debugShowCheckedModeBanner: false,
      theme: ddLightTheme(),
      darkTheme: ddDarkTheme(),
      themeMode: themeModeOf(mode),
      home: const RootShell(),
    );
  }
}

/// Navigation chrome (DESIGN.md §Screens.6): a bottom `NavigationBar` on
/// narrow (< 900px) windows, a left `NavigationRail` on wide ones.
///
/// Also the app-lifecycle hook that resyncs state after the app resumes
/// (picks up whatever an Android background notification action wrote to
/// disk while we were away), and the place the full-screen [AlarmOverlay] is
/// layered above everything else while a reminder is ringing.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

typedef _NavEntry = ({IconData icon, IconData selectedIcon, String label});

class _RootShellState extends State<RootShell> with WidgetsBindingObserver {
  int _index = 0;

  /// Width at and above which the shell switches from a bottom bar to a
  /// side rail (DESIGN.md §Screens.6).
  static const double _wideBreakpoint = 900;

  static const List<Widget> _screens = <Widget>[
    HomeScreen(),
    MedsScreen(),
    WaterScreen(),
    HistoryScreen(),
  ];

  static const List<_NavEntry> _destinations = <_NavEntry>[
    (icon: Icons.today_outlined, selectedIcon: Icons.today, label: 'Today'),
    (
      icon: Icons.medication_outlined,
      selectedIcon: Icons.medication,
      label: 'Meds',
    ),
    (
      icon: Icons.water_drop_outlined,
      selectedIcon: Icons.water_drop,
      label: 'Water',
    ),
    (
      icon: Icons.history_outlined,
      selectedIcon: Icons.history,
      label: 'History',
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      context.read<AppState>().syncFromDisk();
    }
  }

  void _select(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final alarm = context.watch<AppState>().activeAlarm;
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final body = IndexedStack(index: _index, children: _screens);

    return Stack(
      children: <Widget>[
        wide ? _wideScaffold(body) : _narrowScaffold(body),
        // Above everything (DESIGN.md "AlarmOverlay ... full-screen"): a
        // reminder must be seen and answered before anything else.
        if (alarm != null) Positioned.fill(child: AlarmOverlay(alarm: alarm)),
      ],
    );
  }

  Widget _narrowScaffold(Widget body) {
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: <Widget>[
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }

  Widget _wideScaffold(Widget body) {
    return Scaffold(
      body: Row(
        children: <Widget>[
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: _select,
            labelType: NavigationRailLabelType.all,
            destinations: <NavigationRailDestination>[
              for (final d in _destinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
}
