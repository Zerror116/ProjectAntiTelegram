import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  static const _lightSeed = Color(0xFF2F6BFF);
  static const _darkSeed = Color(0xFF5DA2FF);
  static const _baseRadius = 20.0;

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
            primary: const Color(0xFF3A7BFF),
            onPrimary: Colors.white,
            secondary: const Color(0xFF2FA8FF),
            onSecondary: Colors.white,
            tertiary: const Color(0xFF2EC6B8),
            onTertiary: const Color(0xFF012625),
            primaryContainer: const Color(0xFFD8E5FF),
            onPrimaryContainer: const Color(0xFF0B1B43),
            secondaryContainer: const Color(0xFFD9EEFF),
            onSecondaryContainer: const Color(0xFF06243F),
            tertiaryContainer: const Color(0xFFD1F4EF),
            onTertiaryContainer: const Color(0xFF072B28),
            surface: const Color(0xFFF5F8FC),
            surfaceContainerLowest: const Color(0xFFFFFFFF),
            surfaceContainerLow: const Color(0xFFF0F5FC),
            surfaceContainer: const Color(0xFFE8EEF7),
            surfaceContainerHigh: const Color(0xFFDCE5F2),
            surfaceContainerHighest: const Color(0xFFD2DEEE),
            onSurface: const Color(0xFF101828),
            onSurfaceVariant: const Color(0xFF566173),
            outline: const Color(0xFF8796AB),
            outlineVariant: const Color(0xFFC7D2E1),
            shadow: const Color(0xFF0A1224),
            error: const Color(0xFFD64545),
            errorContainer: const Color(0xFFFFE0DE),
            onErrorContainer: const Color(0xFF42100E),
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
            primary: const Color(0xFF73A8FF),
            onPrimary: const Color(0xFF051B39),
            secondary: const Color(0xFF6CC3FF),
            onSecondary: const Color(0xFF06253D),
            tertiary: const Color(0xFF58D3C4),
            onTertiary: const Color(0xFF052A27),
            primaryContainer: const Color(0xFF173359),
            onPrimaryContainer: const Color(0xFFDBEAFF),
            secondaryContainer: const Color(0xFF112F49),
            onSecondaryContainer: const Color(0xFFD7EEFF),
            tertiaryContainer: const Color(0xFF133735),
            onTertiaryContainer: const Color(0xFFD4FBF5),
            surface: const Color(0xFF0B1017),
            surfaceContainerLowest: const Color(0xFF060A0F),
            surfaceContainerLow: const Color(0xFF101720),
            surfaceContainer: const Color(0xFF151E29),
            surfaceContainerHigh: const Color(0xFF1C2734),
            surfaceContainerHighest: const Color(0xFF243142),
            onSurface: const Color(0xFFF4F7FB),
            onSurfaceVariant: const Color(0xFF9EAEBD),
            outline: const Color(0xFF4B5C70),
            outlineVariant: const Color(0xFF273546),
            shadow: Colors.black,
            error: const Color(0xFFFF827A),
            errorContainer: const Color(0xFF4A1C1C),
            onErrorContainer: const Color(0xFFFFE1DF),
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
    final isDark = scheme.brightness == Brightness.dark;
    final onSurfaceColor = isDark
        ? (highContrast ? Colors.white : const Color(0xFFF5F8FC))
        : (highContrast ? const Color(0xFF0F172A) : scheme.onSurface);
    final onSurfaceVariantColor = isDark
        ? (highContrast ? const Color(0xFFCFD8E3) : const Color(0xFFA2B1C2))
        : (highContrast ? const Color(0xFF475569) : scheme.onSurfaceVariant);
    final fieldFillColor = highContrast
        ? (isDark ? const Color(0xFF182230) : const Color(0xFFFFFFFF))
        : scheme.surfaceContainerLow;
    final cardColor = highContrast
        ? (isDark ? const Color(0xFF141D29) : const Color(0xFFFFFFFF))
        : scheme.surfaceContainerLow;
    final cardBorderColor = isDark
        ? scheme.outlineVariant.withValues(alpha: 0.88)
        : scheme.outlineVariant.withValues(alpha: 0.92);

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: scheme.brightness,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashFactory: InkRipple.splashFactory,
      visualDensity: visualDensity,
      fontFamily: GoogleFonts.manrope().fontFamily,
    );

    final effectiveCardScale = cardScale.clamp(0.85, 1.25);
    final baseRadius = _baseRadius * effectiveCardScale;
    final textTheme = _buildTextTheme(
      base,
      onSurfaceColor,
      onSurfaceVariantColor,
    );

    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(baseRadius - 4),
      borderSide: BorderSide(color: scheme.outlineVariant, width: 1.05),
    );

    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: textTheme.apply(
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
          letterSpacing: -0.2,
        ),
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(baseRadius),
          side: BorderSide(color: cardBorderColor),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(baseRadius + 6),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(baseRadius + 4),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        modalBackgroundColor: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(baseRadius + 10),
          ),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.surfaceContainerHigh,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: onSurfaceColor,
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(baseRadius - 2),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: scheme.onPrimary,
          backgroundColor: scheme.primary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(baseRadius - 6),
          ),
          minimumSize: const Size(0, 46),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: scheme.onPrimary,
          backgroundColor: scheme.primary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(baseRadius - 6),
          ),
          minimumSize: const Size(0, 46),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: onSurfaceColor,
          side: BorderSide(color: scheme.outline, width: 1.1),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(baseRadius - 6),
          ),
          minimumSize: const Size(0, 46),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: onSurfaceVariantColor,
          backgroundColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(baseRadius - 8),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fieldFillColor,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(
            color: scheme.primary,
            width: highContrast ? 1.7 : 1.35,
          ),
        ),
        errorBorder: inputBorder.copyWith(
          borderSide: BorderSide(
            color: scheme.error,
            width: highContrast ? 1.35 : 1.15,
          ),
        ),
        focusedErrorBorder: inputBorder.copyWith(
          borderSide: BorderSide(
            color: scheme.error,
            width: highContrast ? 1.65 : 1.35,
          ),
        ),
        labelStyle: textTheme.bodyMedium?.copyWith(
          color: onSurfaceVariantColor,
        ),
        floatingLabelStyle: textTheme.labelMedium?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(color: onSurfaceVariantColor),
        helperStyle: textTheme.bodySmall?.copyWith(
          color: onSurfaceVariantColor,
        ),
        prefixIconColor: onSurfaceVariantColor,
        suffixIconColor: onSurfaceVariantColor,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: onSurfaceVariantColor,
        textColor: onSurfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(baseRadius - 2),
        ),
        dense: false,
        minTileHeight: 52,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        selectedItemColor: scheme.primary,
        unselectedItemColor: onSurfaceVariantColor,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow.withValues(
          alpha: isDark ? 0.96 : 0.98,
        ),
        elevation: 0,
        indicatorColor: scheme.primaryContainer,
        height: 70,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final active = states.contains(WidgetState.selected);
          return textTheme.labelSmall?.copyWith(
            color: active ? scheme.onPrimaryContainer : onSurfaceVariantColor,
            fontWeight: active ? FontWeight.w800 : FontWeight.w700,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
        unselectedIconTheme: IconThemeData(color: onSurfaceVariantColor),
        selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w800,
        ),
        unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: onSurfaceVariantColor,
          fontWeight: FontWeight.w700,
        ),
        indicatorColor: scheme.primaryContainer,
      ),
      chipTheme: base.chipTheme.copyWith(
        side: BorderSide(color: scheme.outlineVariant),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(baseRadius - 10),
        ),
        labelStyle: textTheme.labelMedium?.copyWith(
          color: onSurfaceColor,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
        backgroundColor: scheme.surfaceContainerHighest,
        selectedColor: scheme.primaryContainer,
      ),
      tabBarTheme: TabBarThemeData(
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        labelColor: scheme.onPrimaryContainer,
        unselectedLabelColor: onSurfaceVariantColor,
        indicator: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(baseRadius - 8),
        ),
        labelStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
        unselectedLabelStyle: textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: visualDensity,
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(baseRadius - 8),
            ),
          ),
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStatePropertyAll(scheme.outlineVariant),
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
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(baseRadius - 2),
        ),
      ),
      dividerColor: scheme.outlineVariant,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(baseRadius - 10),
          border: Border.all(color: scheme.outlineVariant),
        ),
        textStyle: textTheme.bodySmall?.copyWith(
          color: onSurfaceColor,
          fontWeight: FontWeight.w700,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        circularTrackColor: scheme.surfaceContainerHighest,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
      searchBarTheme: SearchBarThemeData(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(baseRadius),
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        elevation: const WidgetStatePropertyAll(0),
        textStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
        hintStyle: WidgetStatePropertyAll(
          textTheme.bodyMedium?.copyWith(color: onSurfaceVariantColor),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(baseRadius - 2),
              side: BorderSide(color: scheme.outlineVariant),
            ),
          ),
        ),
      ),
      splashColor: scheme.primary.withValues(alpha: 0.08),
      highlightColor: scheme.primary.withValues(alpha: 0.05),
      hoverColor: scheme.primary.withValues(alpha: 0.05),
      focusColor: scheme.primary.withValues(alpha: 0.10),
    );
  }

  static TextTheme _buildTextTheme(
    ThemeData base,
    Color onSurfaceColor,
    Color onSurfaceVariantColor,
  ) {
    final manrope = GoogleFonts.manropeTextTheme(base.textTheme);
    return manrope
        .copyWith(
          displaySmall: manrope.displaySmall?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1.02,
            letterSpacing: -1.0,
          ),
          headlineSmall: manrope.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
          titleLarge: manrope.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.35,
            height: 1.08,
          ),
          titleMedium: manrope.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
            height: 1.1,
          ),
          titleSmall: manrope.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.1,
            height: 1.1,
          ),
          bodyLarge: manrope.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
            height: 1.38,
            letterSpacing: -0.05,
          ),
          bodyMedium: manrope.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            height: 1.34,
            letterSpacing: -0.02,
          ),
          bodySmall: manrope.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            height: 1.28,
          ),
          labelLarge: manrope.labelLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 0.1,
            height: 1.0,
          ),
          labelMedium: manrope.labelMedium?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 0.1,
            height: 1.0,
          ),
          labelSmall: manrope.labelSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 0.18,
            height: 1.0,
          ),
        )
        .apply(bodyColor: onSurfaceColor, displayColor: onSurfaceColor)
        .copyWith(
          bodySmall: manrope.bodySmall?.copyWith(color: onSurfaceVariantColor),
          labelSmall: manrope.labelSmall?.copyWith(
            color: onSurfaceVariantColor,
          ),
        );
  }
}
