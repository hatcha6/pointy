import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import 'cards_tokens.dart';

/// The card app's theme, built on the Daftar brand palette and type face.
///
/// Restraint is the point: teal is rationed to the one primary action and to
/// what is selected, amber to promotions; everything else is ink on a calm
/// page, so the card art carries the colour.
abstract final class CardsTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  /// Teal for text that acts: brand teal on light, a brighter one on dark,
  /// where brand teal is too faint to read on the page.
  static Color link(ThemeData theme) => theme.brightness == Brightness.dark
      ? PointyColorsDark.primaryStrong
      : PointyColors.primary;

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final ink = dark ? PointyColorsDark.ink : const Color(0xFF15181D);
    final muted = dark ? PointyColorsDark.mutedInk : const Color(0xFF6B7280);
    final surface = dark ? const Color(0xFF161B22) : Colors.white;
    final page = dark ? const Color(0xFF0B0F14) : const Color(0xFFF7F6F3);
    final line = dark ? const Color(0xFF262D36) : const Color(0xFFE7E4DE);
    final fill = dark ? const Color(0xFF1D232B) : const Color(0xFFF0EEEA);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: PointyColors.primary,
          brightness: brightness,
        ).copyWith(
          primary: PointyColors.primary,
          onPrimary: Colors.white,
          primaryContainer: dark
              ? PointyColorsDark.primaryContainer
              : PointyColors.primaryContainer,
          onPrimaryContainer: dark
              ? PointyColorsDark.primaryDark
              : PointyColors.primaryDark,
          secondary: dark
              ? PointyColorsDark.accentAmber
              : PointyColors.accentAmber,
          onSecondary: PointyColors.ink,
          secondaryContainer: dark
              ? PointyColorsDark.amberContainer
              : PointyColors.amberContainer,
          onSecondaryContainer: ink,
          tertiary: dark ? PointyColorsDark.success : PointyColors.success,
          error: dark ? PointyColorsDark.danger : PointyColors.danger,
          surface: surface,
          onSurface: ink,
          onSurfaceVariant: muted,
          surfaceContainerHighest: fill,
          outline: line,
          outlineVariant: line,
        );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
    );
    final text = _ramp(PointyTypography.textTheme(base.textTheme))
        .apply(bodyColor: ink, displayColor: ink);
    const capsule = StadiumBorder();
    final buttonText = text.titleMedium?.copyWith(fontWeight: FontWeight.w700);
    return base.copyWith(
      scaffoldBackgroundColor: page,
      canvasColor: page,
      textTheme: text,
      splashFactory: InkSparkle.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: page,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CardsRadii.card),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(CardsSizes.button),
          shape: capsule,
          textStyle: buttonText,
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(CardsSizes.button),
          shape: capsule,
          side: BorderSide(color: ink.withValues(alpha: dark ? 0.4 : 0.85)),
          foregroundColor: ink,
          textStyle: buttonText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(CardsSizes.touch, CardsSizes.touch),
          shape: capsule,
          foregroundColor: dark
              ? PointyColorsDark.primaryStrong
              : PointyColors.primary,
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(CardsSizes.touch, CardsSizes.touch),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: CardsSpace.lg,
          vertical: CardsSpace.lg,
        ),
        hintStyle: text.bodyLarge?.copyWith(color: muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CardsRadii.field),
          borderSide: BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CardsRadii.field),
          borderSide: BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CardsRadii.field),
          borderSide: BorderSide(color: ink, width: 1.6),
        ),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? PointyColors.primary
              : fill,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        thumbColor: const WidgetStatePropertyAll(Colors.white),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface.withValues(alpha: dark ? 0.82 : 0.88),
        surfaceTintColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        height: 64,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? ink : muted,
            size: 26,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => text.labelSmall?.copyWith(
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? ink : muted,
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: line,
        modalBarrierColor: Colors.black.withValues(alpha: 0.4),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(CardsRadii.sheet),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CardsRadii.card),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? const Color(0xFF2A313B) : ink,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
        shape: const StadiumBorder(),
        insetPadding: const EdgeInsets.fromLTRB(
          CardsSpace.gutter,
          0,
          CardsSpace.gutter,
          CardsSpace.lg,
        ),
      ),
      dividerTheme: DividerThemeData(color: line, thickness: 0.8, space: 1),
      listTileTheme: ListTileThemeData(
        iconColor: muted,
        textColor: ink,
        minVerticalPadding: CardsSpace.md,
      ),
    );
  }

  /// Apple-like sizes and three weights: 700 for titles, 500–600 for labels,
  /// 400 for reading.
  static TextTheme _ramp(TextTheme t) => t.copyWith(
    headlineLarge: t.headlineLarge?.copyWith(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      height: 1.2,
    ),
    headlineMedium: t.headlineMedium?.copyWith(
      fontSize: 26,
      fontWeight: FontWeight.w700,
    ),
    headlineSmall: t.headlineSmall?.copyWith(
      fontSize: 22,
      fontWeight: FontWeight.w700,
    ),
    titleLarge: t.titleLarge?.copyWith(
      fontSize: 19,
      fontWeight: FontWeight.w700,
    ),
    titleMedium: t.titleMedium?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: t.titleSmall?.copyWith(
      fontSize: 14.5,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: t.bodyLarge?.copyWith(fontSize: 16, fontWeight: FontWeight.w400),
    bodyMedium: t.bodyMedium?.copyWith(
      fontSize: 14.5,
      fontWeight: FontWeight.w400,
    ),
    bodySmall: t.bodySmall?.copyWith(fontSize: 13, fontWeight: FontWeight.w400),
    labelLarge: t.labelLarge?.copyWith(
      fontSize: 14.5,
      fontWeight: FontWeight.w600,
    ),
    labelMedium: t.labelMedium?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w500,
    ),
    labelSmall: t.labelSmall?.copyWith(
      fontSize: 11.5,
      fontWeight: FontWeight.w500,
    ),
  );
}
