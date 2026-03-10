import 'package:flutter/material.dart';

class AppTheme {
  static const _lightSeed = Color(0xFF2F6BFF);
  static const _darkSeed = Color(0xFF7A4DFF);

  static ThemeData light({
    Color? seedColor,
    VisualDensity visualDensity = VisualDensity.standard,
    double cardScale = 1,
  }) {
    final activeSeed = seedColor ?? _lightSeed;
    final scheme = ColorScheme.fromSeed(
      seedColor: activeSeed,
      brightness: Brightness.light,
    );
    final adapted = seedColor == null
        ? scheme.copyWith(
            primary: const Color(0xFF2F6BFF),
            onPrimary: Colors.white,
            secondary: const Color(0xFF4D8DFF),
            onSecondary: Colors.white,
            tertiary: const Color(0xFF37A9FF),
            onTertiary: const Color(0xFF001B2D),
            primaryContainer: const Color(0xFFDDE5FF),
            onPrimaryContainer: const Color(0xFF001846),
            secondaryContainer: const Color(0xFFDDE8FF),
            onSecondaryContainer: const Color(0xFF08214A),
            tertiaryContainer: const Color(0xFFD1EEFF),
            onTertiaryContainer: const Color(0xFF00243A),
            surface: const Color(0xFFF3F7FF),
            surfaceContainerLowest: const Color(0xFFFFFFFF),
            surfaceContainerLow: const Color(0xFFEBF2FF),
            surfaceContainer: const Color(0xFFE1ECFF),
            surfaceContainerHigh: const Color(0xFFD6E5FF),
            surfaceContainerHighest: const Color(0xFFC9DCFF),
            onSurface: const Color(0xFF0E1B3A),
            onSurfaceVariant: const Color(0xFF3E4B70),
            outline: const Color(0xFF6F82B8),
            outlineVariant: const Color(0xFF9FB2E0),
          )
        : scheme;
    return _buildTheme(
      adapted,
      visualDensity: visualDensity,
      cardScale: cardScale,
    );
  }

  static ThemeData dark({
    Color? seedColor,
    VisualDensity visualDensity = VisualDensity.standard,
    double cardScale = 1,
  }) {
    final activeSeed = seedColor ?? _darkSeed;
    final scheme = ColorScheme.fromSeed(
      seedColor: activeSeed,
      brightness: Brightness.dark,
    );
    final adapted = seedColor == null
        ? scheme.copyWith(
            primary: const Color(0xFFA88BFF),
            onPrimary: const Color(0xFF1B1332),
            secondary: const Color(0xFF8C70FF),
            onSecondary: const Color(0xFF181030),
            tertiary: const Color(0xFFD28CFF),
            onTertiary: const Color(0xFF2A103B),
            primaryContainer: const Color(0xFF3A2E66),
            onPrimaryContainer: const Color(0xFFE8DEFF),
            secondaryContainer: const Color(0xFF33295B),
            onSecondaryContainer: const Color(0xFFE4DBFF),
            tertiaryContainer: const Color(0xFF4D2D63),
            onTertiaryContainer: const Color(0xFFFFD8FA),
            surface: const Color(0xFF15111E),
            surfaceContainerLowest: const Color(0xFF0E0A16),
            surfaceContainerLow: const Color(0xFF1C1628),
            surfaceContainer: const Color(0xFF241C33),
            surfaceContainerHigh: const Color(0xFF2D2440),
            surfaceContainerHighest: const Color(0xFF39304E),
            onSurface: const Color(0xFFF0ECFA),
            onSurfaceVariant: const Color(0xFFD3CCE3),
            outline: const Color(0xFFA59BBF),
            outlineVariant: const Color(0xFF4D4461),
          )
        : scheme;
    return _buildTheme(
      adapted,
      visualDensity: visualDensity,
      cardScale: cardScale,
    );
  }

  static ThemeData _buildTheme(
    ColorScheme scheme, {
    required VisualDensity visualDensity,
    required double cardScale,
  }) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashFactory: InkRipple.splashFactory,
      visualDensity: visualDensity,
    );

    final effectiveCardScale = cardScale.clamp(0.85, 1.25);

    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      primaryTextTheme: base.primaryTextTheme.apply(
        bodyColor: scheme.onPrimary,
        displayColor: scheme.onPrimary,
      ),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      primaryIconTheme: IconThemeData(color: scheme.onPrimary),
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18 * effectiveCardScale),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        modalBackgroundColor: scheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.surfaceContainerHigh,
        contentTextStyle: TextStyle(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 1.3),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      dividerColor: scheme.outlineVariant,
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        circularTrackColor: scheme.surfaceContainerHighest,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
    );
  }
}
