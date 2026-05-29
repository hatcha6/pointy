import 'package:flutter/material.dart';

import 'pointy_colors.dart';

abstract final class PointyRadii {
  static const double card = 8;
  static const double input = 12;
  static const double button = 12;
  static const double chip = 10;
  static const double sheet = 28;
  static const double dialog = 18;
}

abstract final class PointyDimensions {
  static const double iconButton = 48;
  static const double buttonHeight = 48;
  static const double primaryActionHeight = 64;
  static const double metricTileMinHeight = 120;
  static const double denseGap = 8;
  static const double sectionGap = 20;
}

abstract final class PointyComponentStyles {
  static const BorderSide defaultBorder = BorderSide(color: PointyColors.line);

  static RoundedRectangleBorder shape(double radius) {
    return RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
  }

  static RoundedRectangleBorder outlinedShape(double radius) {
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: defaultBorder,
    );
  }

  static AppBarThemeData appBarTheme(TextTheme textTheme) {
    return AppBarThemeData(
      backgroundColor: PointyColors.page,
      foregroundColor: PointyColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: PointyColors.ink,
        fontSize: 24,
        fontWeight: FontWeight.w700,
      ),
      iconTheme: const IconThemeData(color: PointyColors.ink),
      actionsIconTheme: const IconThemeData(color: PointyColors.ink),
    );
  }

  static AppBarThemeData darkAppBarTheme(TextTheme textTheme) {
    return AppBarThemeData(
      backgroundColor: PointyColors.darkTopBar,
      foregroundColor: PointyColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: PointyColors.surface,
        fontSize: 26,
        fontWeight: FontWeight.w700,
      ),
      iconTheme: const IconThemeData(color: PointyColors.surface),
      actionsIconTheme: const IconThemeData(color: PointyColors.surface),
    );
  }

  static InputDecorationThemeData inputDecorationTheme(TextTheme textTheme) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(PointyRadii.input),
      borderSide: defaultBorder,
    );

    return InputDecorationThemeData(
      filled: true,
      fillColor: PointyColors.surface,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: const BorderSide(color: PointyColors.primary, width: 1.4),
      ),
      errorBorder: border.copyWith(
        borderSide: const BorderSide(color: PointyColors.danger),
      ),
      focusedErrorBorder: border.copyWith(
        borderSide: const BorderSide(color: PointyColors.danger, width: 1.4),
      ),
      contentPadding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 14),
      labelStyle: textTheme.bodyMedium?.copyWith(color: PointyColors.mutedInk),
      hintStyle: textTheme.bodyMedium?.copyWith(color: PointyColors.mutedInk),
      helperStyle: textTheme.bodySmall?.copyWith(color: PointyColors.mutedInk),
      errorStyle: textTheme.bodySmall?.copyWith(color: PointyColors.danger),
      prefixIconColor: PointyColors.mutedInk,
      suffixIconColor: PointyColors.mutedInk,
    );
  }

  static FilledButtonThemeData filledButtonTheme(ColorScheme colorScheme) {
    return FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, PointyDimensions.buttonHeight),
        backgroundColor: PointyColors.primary,
        foregroundColor: colorScheme.onPrimary,
        disabledBackgroundColor: PointyColors.line,
        disabledForegroundColor: PointyColors.mutedInk,
        shape: shape(PointyRadii.button),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }

  static OutlinedButtonThemeData outlinedButtonTheme(ColorScheme colorScheme) {
    return OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, PointyDimensions.buttonHeight),
        foregroundColor: PointyColors.primaryStrong,
        disabledForegroundColor: PointyColors.mutedInk,
        side: const BorderSide(color: PointyColors.line),
        shape: shape(PointyRadii.button),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }

  static TextButtonThemeData textButtonTheme() {
    return TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, PointyDimensions.buttonHeight),
        foregroundColor: PointyColors.primaryStrong,
        disabledForegroundColor: PointyColors.mutedInk,
        shape: shape(PointyRadii.button),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }

  static IconButtonThemeData iconButtonTheme() {
    return IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size.square(PointyDimensions.iconButton),
        foregroundColor: PointyColors.ink,
        disabledForegroundColor: PointyColors.mutedInk,
        shape: shape(PointyRadii.button),
      ),
    );
  }

  static ChipThemeData chipTheme(TextTheme textTheme) {
    return ChipThemeData(
      backgroundColor: PointyColors.subtleFill,
      selectedColor: PointyColors.primaryContainer,
      disabledColor: PointyColors.line,
      surfaceTintColor: Colors.transparent,
      side: const BorderSide(color: PointyColors.line),
      shape: shape(PointyRadii.chip),
      labelStyle: textTheme.labelLarge?.copyWith(color: PointyColors.ink),
      secondaryLabelStyle: textTheme.labelLarge?.copyWith(
        color: PointyColors.primaryStrong,
        fontWeight: FontWeight.w600,
      ),
      iconTheme: const IconThemeData(color: PointyColors.primaryStrong),
      padding: const EdgeInsets.symmetric(horizontal: 8),
    );
  }

  static NavigationDrawerThemeData navigationDrawerTheme(TextTheme textTheme) {
    return NavigationDrawerThemeData(
      backgroundColor: PointyColors.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: PointyColors.primaryContainer,
      indicatorShape: shape(PointyRadii.button),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final isSelected = states.contains(WidgetState.selected);
        return textTheme.labelLarge?.copyWith(
          color: isSelected ? PointyColors.primaryDark : PointyColors.ink,
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final isSelected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: isSelected ? PointyColors.primaryDark : PointyColors.mutedInk,
        );
      }),
    );
  }
}
