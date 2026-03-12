import 'package:flutter/material.dart';

class AppTheme {
  static const _lightSeed = Color(0xFF2F6BFF);
  static const _darkSeed = Color(0xFF7A4DFF);
  static const _baseRadius = 18.0;

  static ThemeData light({
    Color? seedColor,
    VisualDensity visualDensity = VisualDensity.standard,
    double cardScale = 1,
    bool highContrast = false,
  }) {
    final activeSeed = seedColor ?? _lightSeed;
    final useFallbackPalette =
        seedColor == null || activeSeed.toARGB32() == _lightSeed.toARGB32();
    final scheme = ColorScheme.fromSeed(
      seedColor: activeSeed,
      brightness: Brightness.light,
    );
    final adapted = useFallbackPalette
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
      highContrast: highContrast,
    );
  }

  static ThemeData dark({
    Color? seedColor,
    VisualDensity visualDensity = VisualDensity.standard,
    double cardScale = 1,
    bool highContrast = false,
  }) {
    final activeSeed = seedColor ?? _darkSeed;
    final useFallbackPalette =
        seedColor == null || activeSeed.toARGB32() == _darkSeed.toARGB32();
    final scheme = ColorScheme.fromSeed(
      seedColor: activeSeed,
      brightness: Brightness.dark,
    );
    final adapted = useFallbackPalette
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
      highContrast: highContrast,
    );
  }

  static ThemeData _buildTheme(
    ColorScheme scheme, {
    required VisualDensity visualDensity,
    required double cardScale,
    required bool highContrast,
  }) {
    final bool isDark = scheme.brightness == Brightness.dark;
    final onSurfaceColor = isDark
        ? (highContrast ? const Color(0xFFFFFFFF) : const Color(0xFFF4EEFF))
        : (highContrast ? const Color(0xFF111827) : scheme.onSurface);
    final onSurfaceVariantColor = isDark
        ? (highContrast ? const Color(0xFFE8DEFF) : const Color(0xFFD5CCE9))
        : (highContrast ? const Color(0xFF334155) : scheme.onSurfaceVariant);
    final fieldFillColor = highContrast
        ? (isDark ? const Color(0xFF2A2140) : const Color(0xFFFFFFFF))
        : scheme.surfaceContainerLowest;
    final cardColor = highContrast
        ? (isDark ? const Color(0xFF2B2340) : const Color(0xFFF9FBFF))
        : scheme.surfaceContainerLow;
    final cardBorderColor = isDark
        ? scheme.outlineVariant.withValues(alpha: 0.35)
        : scheme.outlineVariant.withValues(alpha: 0.55);

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: scheme.brightness,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashFactory: InkRipple.splashFactory,
      visualDensity: visualDensity,
    );

    final effectiveCardScale = cardScale.clamp(0.85, 1.25);
    final baseRadius = _baseRadius * effectiveCardScale;
    final textTheme = base.textTheme
        .copyWith(
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 0.1,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.1,
          ),
          titleSmall: base.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          labelLarge: base.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
          bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.3),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.3),
          bodySmall: base.textTheme.bodySmall?.copyWith(height: 1.25),
        )
        .apply(bodyColor: onSurfaceColor, displayColor: onSurfaceColor);

    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(baseRadius - 2),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );

    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: base.primaryTextTheme.apply(
        bodyColor: scheme.onPrimary,
        displayColor: scheme.onPrimary,
      ),
      iconTheme: IconThemeData(color: onSurfaceVariantColor),
      primaryIconTheme: IconThemeData(color: scheme.onPrimary),
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: onSurfaceColor,
        titleTextStyle: textTheme.titleMedium?.copyWith(
          color: onSurfaceColor,
          fontWeight: FontWeight.w800,
        ),
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(baseRadius),
          side: BorderSide(color: cardBorderColor),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(baseRadius + 6),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        modalBackgroundColor: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(baseRadius + 10),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.surfaceContainerHigh,
        contentTextStyle: TextStyle(
          color: onSurfaceColor,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(baseRadius),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: scheme.onPrimary,
          backgroundColor: scheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(baseRadius - 4),
          ),
          minimumSize: const Size(0, 44),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: scheme.onPrimary,
          backgroundColor: scheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(baseRadius - 4),
          ),
          minimumSize: const Size(0, 44),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: onSurfaceColor,
          side: BorderSide(color: scheme.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(baseRadius - 4),
          ),
          minimumSize: const Size(0, 44),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fieldFillColor,
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(
            color: scheme.primary,
            width: highContrast ? 1.6 : 1.3,
          ),
        ),
        errorBorder: inputBorder.copyWith(
          borderSide: BorderSide(
            color: scheme.error,
            width: highContrast ? 1.3 : 1.1,
          ),
        ),
        focusedErrorBorder: inputBorder.copyWith(
          borderSide: BorderSide(
            color: scheme.error,
            width: highContrast ? 1.6 : 1.3,
          ),
        ),
        labelStyle: TextStyle(color: onSurfaceVariantColor),
        floatingLabelStyle: TextStyle(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
        ),
        hintStyle: TextStyle(color: onSurfaceVariantColor),
        helperStyle: TextStyle(color: onSurfaceVariantColor),
        prefixIconColor: onSurfaceVariantColor,
        suffixIconColor: onSurfaceVariantColor,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: onSurfaceVariantColor,
        textColor: onSurfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(baseRadius),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        selectedItemColor: scheme.primary,
        unselectedItemColor: onSurfaceVariantColor,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final active = states.contains(WidgetState.selected);
          return textTheme.labelSmall?.copyWith(
            color: active ? scheme.onPrimaryContainer : onSurfaceVariantColor,
            fontWeight: active ? FontWeight.w700 : FontWeight.w600,
          );
        }),
      ),
      chipTheme: base.chipTheme.copyWith(
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(baseRadius - 8),
        ),
        labelStyle: textTheme.labelMedium?.copyWith(
          color: onSurfaceColor,
          fontWeight: FontWeight.w600,
        ),
        backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: scheme.primaryContainer,
      ),
      tabBarTheme: TabBarThemeData(
        dividerColor: Colors.transparent,
        labelColor: scheme.onPrimaryContainer,
        unselectedLabelColor: onSurfaceVariantColor,
        indicator: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(baseRadius - 6),
        ),
        labelStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
        unselectedLabelStyle: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: visualDensity,
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(baseRadius - 6),
            ),
          ),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const Icon(Icons.check, size: 14);
          }
          return const Icon(Icons.close, size: 14);
        }),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(baseRadius - 4),
        ),
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
