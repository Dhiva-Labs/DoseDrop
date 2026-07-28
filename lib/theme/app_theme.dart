import 'package:flutter/material.dart';

/// DoseDrop design tokens — the single source of truth (see DESIGN.md).
/// Screens use these constants; never hardcode hex values elsewhere.
class DD {
  DD._();

  // Surfaces & ink — light
  static const bgL = Color(0xFFF6F8F7);
  static const cardL = Color(0xFFFFFFFF);
  static const cardAltL = Color(0xFFEEF2F0);
  static const outlineL = Color(0xFFE2E8E5);
  static const inkL = Color(0xFF16211D);
  static const ink2L = Color(0xFF4A5A54);
  static const ink3L = Color(0xFF78877F);

  // Surfaces & ink — dark
  static const bgD = Color(0xFF0F1412);
  static const cardD = Color(0xFF171D1A);
  static const cardAltD = Color(0xFF1F2622);
  static const outlineD = Color(0xFF2A332E);
  static const inkD = Color(0xFFE8EDEA);
  static const ink2D = Color(0xFFA8B5AE);
  static const ink3D = Color(0xFF7C8A82);

  // Brand
  static const teal = Color(0xFF0D9488);
  static const tealDeep = Color(0xFF0F766E);
  static const onTeal = Color(0xFFFFFFFF);
  static const heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [teal, tealDeep],
  );

  // Water accent
  static const water = Color(0xFF0284C7);
  static const waterFillL = Color(0xFFE0F2FE);
  static const waterAccentD = Color(0xFF38BDF8);

  // Med identity colors — categorical, FIXED order, validated (DESIGN.md)
  static const medColorsLight = [
    Color(0xFF0D9488), // teal
    Color(0xFFC2410C), // orange
    Color(0xFF0284C7), // blue
    Color(0xFF4D7C0F), // olive
    Color(0xFF7C3AED), // violet
    Color(0xFFBE185D), // pink
  ];
  static const medColorsDark = [
    Color(0xFF0D9488), // teal
    Color(0xFFEA580C), // orange
    Color(0xFF0284C7), // blue
    Color(0xFF65A30D), // lime
    Color(0xFF8B5CF6), // violet
    Color(0xFFEC4899), // pink
  ];

  static List<Color> medColors(Brightness b) =>
      b == Brightness.dark ? medColorsDark : medColorsLight;
  static Color medColor(int index, Brightness b) {
    final list = medColors(b);
    return list[index % list.length];
  }

  // Status — reserved, never used for series identity; always paired with icon + label
  static const takenL = Color(0xFF15803D);
  static const takenD = Color(0xFF4ADE80);
  static const snoozedL = Color(0xFFB45309);
  static const snoozedD = Color(0xFFFBBF24);
  static const missedL = Color(0xFFB91C1C);
  static const missedD = Color(0xFFF87171);
  static const skippedL = Color(0xFF64748B);
  static const skippedD = Color(0xFF94A3B8);

  // Geometry
  static const pad = 20.0;
  static const gap = 24.0;
  static const rCard = 20.0;
  static const rButton = 14.0;
  static const rSheet = 28.0;
  static const rTile = 16.0;

  static const tabular = [FontFeature.tabularFigures()];
}

/// Per-brightness resolved tokens, exposed via `DDTheme.of(context)`.
class DDTheme {
  final Brightness brightness;
  const DDTheme(this.brightness);

  bool get isDark => brightness == Brightness.dark;

  Color get bg => isDark ? DD.bgD : DD.bgL;
  Color get card => isDark ? DD.cardD : DD.cardL;
  Color get cardAlt => isDark ? DD.cardAltD : DD.cardAltL;
  Color get outline => isDark ? DD.outlineD : DD.outlineL;
  Color get ink => isDark ? DD.inkD : DD.inkL;
  Color get ink2 => isDark ? DD.ink2D : DD.ink2L;
  Color get ink3 => isDark ? DD.ink3D : DD.ink3L;
  Color get taken => isDark ? DD.takenD : DD.takenL;
  Color get snoozed => isDark ? DD.snoozedD : DD.snoozedL;
  Color get missed => isDark ? DD.missedD : DD.missedL;
  Color get skipped => isDark ? DD.skippedD : DD.skippedL;
  Color get waterAccent => isDark ? DD.waterAccentD : DD.water;
  List<Color> get medColors => DD.medColors(brightness);
  Color medColor(int i) => DD.medColor(i, brightness);

  static DDTheme of(BuildContext context) =>
      DDTheme(Theme.of(context).brightness);
}

TextTheme _textTheme(Color ink, Color ink2) => TextTheme(
      displaySmall: TextStyle(
          fontSize: 30, fontWeight: FontWeight.w800, color: ink, height: 1.15),
      headlineMedium:
          TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: ink),
      titleMedium:
          TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: ink),
      bodyMedium: TextStyle(
          fontSize: 15, fontWeight: FontWeight.w400, color: ink, height: 1.45),
      labelLarge:
          TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ink2),
      bodySmall:
          TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: ink2),
    );

ThemeData _base(Brightness b) {
  final t = DDTheme(b);
  final scheme = ColorScheme.fromSeed(
    seedColor: DD.teal,
    brightness: b,
    primary: DD.teal,
    onPrimary: DD.onTeal,
    surface: t.bg,
    onSurface: t.ink,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    scaffoldBackgroundColor: t.bg,
    canvasColor: t.bg,
    cardColor: t.card,
    dividerColor: t.outline,
    textTheme: _textTheme(t.ink, t.ink2),
    appBarTheme: AppBarTheme(
      backgroundColor: t.bg,
      foregroundColor: t.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: t.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DD.rCard),
        side: BorderSide(color: t.outline),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: DD.teal,
        foregroundColor: DD.onTeal,
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DD.rButton)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: t.ink2,
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DD.rButton)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? DD.onTeal : t.ink3),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? DD.teal : t.cardAlt),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: t.card,
      indicatorColor: DD.teal.withValues(alpha: 0.15),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
          color: s.contains(WidgetState.selected) ? DD.teal : t.ink3)),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: s.contains(WidgetState.selected) ? DD.teal : t.ink3)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: t.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(DD.rSheet)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.card,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DD.rCard)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: t.ink,
      contentTextStyle: TextStyle(color: t.bg, fontSize: 14),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DD.rButton)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: DD.teal,
      foregroundColor: DD.onTeal,
    ),
  );
}

ThemeData ddLightTheme() => _base(Brightness.light);
ThemeData ddDarkTheme() => _base(Brightness.dark);
