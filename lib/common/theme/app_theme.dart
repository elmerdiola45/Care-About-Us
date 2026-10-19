import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

/// IBM Plex Mono, for codes people read character by character (Rx
/// numbers, patient and request IDs) so they don't blend into prose.
TextStyle appMono({
  double fontSize = 12,
  FontWeight fontWeight = FontWeight.w500,
  Color? color,
}) => GoogleFonts.ibmPlexMono(
  fontSize: fontSize,
  fontWeight: fontWeight,
  color: color,
);

/// The app's type scale (IBM Plex Sans): five sizes — 28, 20, 16, 14, 12
/// (11 only for count badges) — and three weights, 400/500/600. Screens set
/// sizes on their own TextStyles; these are the defaults stock widgets use.
TextTheme _textTheme(TextTheme base) {
  TextStyle s(TextStyle? t, double size, double height, FontWeight weight) =>
      t!.copyWith(
        fontSize: size,
        height: height / size,
        fontWeight: weight,
        letterSpacing: 0,
      );
  final t = GoogleFonts.ibmPlexSansTextTheme(base);
  return t.copyWith(
    displayLarge: s(t.displayLarge, 28, 34, FontWeight.w600),
    displayMedium: s(t.displayMedium, 28, 34, FontWeight.w600),
    displaySmall: s(t.displaySmall, 28, 34, FontWeight.w600),
    headlineLarge: s(t.headlineLarge, 28, 34, FontWeight.w600),
    headlineMedium: s(t.headlineMedium, 28, 34, FontWeight.w600),
    headlineSmall: s(t.headlineSmall, 20, 28, FontWeight.w600),
    titleLarge: s(t.titleLarge, 20, 28, FontWeight.w600),
    titleMedium: s(t.titleMedium, 16, 24, FontWeight.w600),
    titleSmall: s(t.titleSmall, 14, 20, FontWeight.w600),
    bodyLarge: s(t.bodyLarge, 16, 24, FontWeight.w400),
    bodyMedium: s(t.bodyMedium, 14, 20, FontWeight.w400),
    bodySmall: s(t.bodySmall, 12, 16, FontWeight.w400),
    labelLarge: s(t.labelLarge, 14, 20, FontWeight.w500),
    labelMedium: s(t.labelMedium, 12, 16, FontWeight.w500),
    labelSmall: s(t.labelSmall, 11, 16, FontWeight.w500),
  );
}

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
  final baseText = _textTheme(
    ThemeData(useMaterial3: true, colorScheme: scheme).textTheme,
  );
  final buttonText = baseText.labelLarge!;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: GoogleFonts.ibmPlexSans().fontFamily,
    textTheme: baseText,
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
        fontSize: 16,
        fontWeight: FontWeight.w600,
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
        shape: const StadiumBorder(),
        minimumSize: const Size(64, 44),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        textStyle: buttonText,
        shape: const StadiumBorder(),
        minimumSize: const Size(64, 44),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.teal,
        textStyle: buttonText,
        side: const BorderSide(color: AppColors.border),
        shape: const StadiumBorder(),
        minimumSize: const Size(64, 44),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.teal,
        textStyle: buttonText,
        shape: const StadiumBorder(),
        minimumSize: const Size(64, 44),
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
      labelStyle: baseText.labelLarge!.copyWith(fontSize: 14),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titleTextStyle: baseText.titleLarge!.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
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
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelStyle: baseText.labelSmall!.copyWith(fontSize: 12),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: AppColors.surface,
      indicatorColor: AppColors.tealPale,
      useIndicator: true,
      selectedIconTheme: const IconThemeData(color: AppColors.teal),
      unselectedIconTheme: const IconThemeData(color: AppColors.textSecondary),
      selectedLabelTextStyle: baseText.labelLarge!.copyWith(
        color: AppColors.teal,
        fontWeight: FontWeight.w600,
        fontSize: 14,
      ),
      unselectedLabelTextStyle: baseText.labelLarge!.copyWith(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w500,
        fontSize: 14,
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
