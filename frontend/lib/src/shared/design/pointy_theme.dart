import 'package:flutter/material.dart';

import 'pointy_colors.dart';
import 'pointy_component_styles.dart';
import 'pointy_theme_extensions.dart';
import 'pointy_typography.dart';

abstract final class PointyTheme {
  static ThemeData light() {
    const semanticColors = PointySemanticColors.light();
    final seedScheme = ColorScheme.fromSeed(
      seedColor: PointyColors.primary,
      brightness: Brightness.light,
    );
    final colorScheme = seedScheme.copyWith(
      primary: PointyColors.primary,
      onPrimary: PointyColors.surface,
      primaryContainer: PointyColors.primaryContainer,
      onPrimaryContainer: PointyColors.primaryDark,
      secondary: PointyColors.accentAmber,
      onSecondary: PointyColors.ink,
      secondaryContainer: PointyColors.amberContainer,
      onSecondaryContainer: PointyColors.ink,
      tertiary: PointyColors.success,
      error: PointyColors.danger,
      onError: PointyColors.surface,
      surface: PointyColors.surface,
      onSurface: PointyColors.ink,
      outline: PointyColors.line,
      outlineVariant: PointyColors.line,
    );
    final baseTheme = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: Brightness.light,
      fontFamily: PointyTypography.fontFamily,
    );
    final textTheme = PointyTypography.textTheme(
      baseTheme.textTheme,
    ).apply(bodyColor: PointyColors.ink, displayColor: PointyColors.ink);

    return baseTheme.copyWith(
      scaffoldBackgroundColor: PointyColors.page,
      textTheme: textTheme,
      hoverColor: PointyColors.ink.withValues(alpha: 0.04),
      focusColor: PointyColors.ink.withValues(alpha: 0.08),
      highlightColor: PointyColors.ink.withValues(alpha: 0.06),
      splashColor: PointyColors.ink.withValues(alpha: 0.10),
      extensions: const [semanticColors],
      appBarTheme: PointyComponentStyles.appBarTheme(textTheme),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: PointyColors.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: PointyColors.surface,
        modalBarrierColor: PointyColors.ink.withValues(alpha: 0.42),
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(PointyRadii.sheet),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: PointyColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: PointyComponentStyles.outlinedShape(PointyRadii.card),
      ),
      chipTheme: PointyComponentStyles.chipTheme(textTheme),
      dialogTheme: DialogThemeData(
        backgroundColor: PointyColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: PointyComponentStyles.shape(PointyRadii.dialog),
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: textTheme.bodyMedium,
      ),
      dividerTheme: const DividerThemeData(
        color: PointyColors.line,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: PointyComponentStyles.filledButtonTheme(colorScheme),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: PointyColors.primary,
        foregroundColor: PointyColors.surface,
        elevation: 0,
        focusElevation: 1,
        hoverElevation: 1,
        highlightElevation: 1,
      ),
      iconButtonTheme: PointyComponentStyles.iconButtonTheme(),
      inputDecorationTheme: PointyComponentStyles.inputDecorationTheme(
        textTheme,
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: PointyColors.mutedInk,
        textColor: PointyColors.ink,
        minVerticalPadding: 8,
      ),
      navigationDrawerTheme: PointyComponentStyles.navigationDrawerTheme(
        textTheme,
      ),
      outlinedButtonTheme: PointyComponentStyles.outlinedButtonTheme(
        colorScheme,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: PointyColors.ink,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: PointyColors.surface,
        ),
        behavior: SnackBarBehavior.floating,
        shape: PointyComponentStyles.shape(PointyRadii.button),
      ),
      textButtonTheme: PointyComponentStyles.textButtonTheme(),
    );
  }
}
