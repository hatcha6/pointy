import 'package:flutter/material.dart';

import 'pointy_colors.dart';
import 'pointy_component_styles.dart';
import 'pointy_theme_extensions.dart';
import 'pointy_typography.dart';

abstract final class PointyTheme {
  static ThemeData light() =>
      _build(const PointySemanticColors.light(), Brightness.light);

  static ThemeData dark() =>
      _build(const PointySemanticColors.dark(), Brightness.dark);

  static ThemeData _build(PointySemanticColors c, Brightness brightness) {
    final seedScheme = ColorScheme.fromSeed(
      seedColor: c.primary,
      brightness: brightness,
    );
    final colorScheme = seedScheme.copyWith(
      primary: c.primary,
      // The primary fill stays brand teal in both themes, so white reads on it.
      onPrimary: Colors.white,
      primaryContainer: c.primaryContainer,
      onPrimaryContainer: c.primaryDark,
      secondary: c.accentAmber,
      // Amber stays light in both themes; dark ink keeps text legible on it.
      onSecondary: PointyColors.ink,
      secondaryContainer: c.amberContainer,
      onSecondaryContainer: c.ink,
      tertiary: c.success,
      error: c.danger,
      onError: c.surface,
      surface: c.surface,
      onSurface: c.ink,
      outline: c.line,
      outlineVariant: c.line,
    );
    final baseTheme = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: brightness,
      fontFamily: PointyTypography.fontFamily,
    );
    final textTheme = PointyTypography.textTheme(
      baseTheme.textTheme,
    ).apply(bodyColor: c.ink, displayColor: c.ink);

    return baseTheme.copyWith(
      scaffoldBackgroundColor: c.page,
      textTheme: textTheme,
      hoverColor: c.ink.withOpacity(0.04),
      focusColor: c.ink.withOpacity(0.08),
      highlightColor: c.ink.withOpacity(0.06),
      splashColor: c.ink.withOpacity(0.10),
      extensions: [c],
      appBarTheme: PointyComponentStyles.appBarTheme(c, textTheme),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: c.surface,
        modalBarrierColor: c.shadow.withOpacity(0.42),
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(PointyRadii.sheet),
          ),
        ),
      ),
      cardTheme: CardTheme(
        color: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: PointyComponentStyles.outlinedShape(PointyRadii.card, c.line),
      ),
      chipTheme: PointyComponentStyles.chipTheme(c, textTheme),
      dialogTheme: DialogTheme(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        shape: PointyComponentStyles.shape(PointyRadii.dialog),
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: textTheme.bodyMedium,
      ),
      dividerTheme: DividerThemeData(
        color: c.line,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: PointyComponentStyles.filledButtonTheme(c, colorScheme),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: c.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        focusElevation: 1,
        hoverElevation: 1,
        highlightElevation: 1,
      ),
      iconButtonTheme: PointyComponentStyles.iconButtonTheme(c),
      inputDecorationTheme: PointyComponentStyles.inputDecorationTheme(
        c,
        textTheme,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: c.mutedInk,
        textColor: c.ink,
        minVerticalPadding: 8,
      ),
      navigationDrawerTheme: PointyComponentStyles.navigationDrawerTheme(
        c,
        textTheme,
      ),
      outlinedButtonTheme: PointyComponentStyles.outlinedButtonTheme(
        c,
        colorScheme,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.ink,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: c.surface,
        ),
        behavior: SnackBarBehavior.floating,
        shape: PointyComponentStyles.shape(PointyRadii.button),
      ),
      textButtonTheme: PointyComponentStyles.textButtonTheme(c),
    );
  }
}
