import 'package:flutter/material.dart';

import 'app_colors.dart';

/// App-wide Material theme built from [AppColors].
///
/// Screens still style their bespoke cards and headers explicitly; this only
/// supplies consistent defaults for the stock widgets (app bars, buttons,
/// text fields, dialogs, snack bars, navigation) that were previously falling
/// back to raw seed-color Material 3 — the source of mismatched purple-ish
/// tints, square dialogs and differently-sized buttons between screens.
ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.teal,
    primary: AppColors.teal,
    onPrimary: Colors.white,
    secondary: AppColors.tealDark,
    error: AppColors.danger,
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
    surfaceTint: Colors.transparent,
  );

  final radius12 = BorderRadius.circular(12);
  // Derived from the default text theme (not a bare TextStyle) so buttons
  // keep the theme's font family — ButtonStyle.textStyle replaces the
  // inherited style outright rather than merging into it.
  final baseText = ThemeData(useMaterial3: true, colorScheme: scheme).textTheme;
  final buttonText = baseText.labelLarge!.copyWith(
    fontSize: 14.5,
    fontWeight: FontWeight.w600,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    visualDensity: VisualDensity.standard,
    dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      shadowColor: AppColors.border,
      centerTitle: false,
      titleTextStyle: baseText.titleLarge!.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.teal,
        foregroundColor: Colors.white,
        elevation: 0,
        textStyle: buttonText,
        shape: RoundedRectangleBorder(borderRadius: radius12),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        textStyle: buttonText,
        shape: RoundedRectangleBorder(borderRadius: radius12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.teal,
        textStyle: buttonText,
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: radius12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.teal,
        textStyle: buttonText,
        shape: RoundedRectangleBorder(borderRadius: radius12),
      ),
    ),
    // Only label colors here: many screens draw their own borderless fields
    // inside custom containers, and a theme-level fill or focused border
    // would bleed into every one of them.
    inputDecorationTheme: InputDecorationTheme(
      labelStyle: baseText.bodyLarge!.copyWith(color: AppColors.textSecondary),
      floatingLabelStyle: baseText.bodyLarge!.copyWith(color: AppColors.teal),
    ),
    chipTheme: ChipThemeData(
      side: const BorderSide(color: AppColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      selectedColor: AppColors.tealPale,
      labelStyle: baseText.labelLarge!.copyWith(fontSize: 13),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: baseText.titleLarge!.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      // Keeps sheets from stretching edge-to-edge on tablets and desktop.
      constraints: BoxConstraints(maxWidth: 640),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.textPrimary,
      contentTextStyle: baseText.bodyMedium!.copyWith(
        color: Colors.white,
        fontSize: 14,
      ),
      shape: RoundedRectangleBorder(borderRadius: radius12),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: radius12),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.teal,
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: AppColors.surface,
      elevation: 8,
      selectedLabelStyle: baseText.labelSmall!.copyWith(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
      ),
      unselectedLabelStyle: baseText.labelSmall!.copyWith(fontSize: 11.5),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: AppColors.surface,
      indicatorColor: AppColors.tealPale,
      useIndicator: true,
      selectedIconTheme: const IconThemeData(color: AppColors.teal),
      unselectedIconTheme: const IconThemeData(color: AppColors.textSecondary),
      selectedLabelTextStyle: baseText.labelLarge!.copyWith(
        color: AppColors.teal,
        fontWeight: FontWeight.w700,
        fontSize: 13.5,
      ),
      unselectedLabelTextStyle: baseText.labelLarge!.copyWith(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w500,
        fontSize: 13.5,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: AppColors.textPrimary,
        borderRadius: BorderRadius.circular(8),
      ),
    ),
  );
}
