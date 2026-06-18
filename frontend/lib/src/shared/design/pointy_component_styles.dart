import 'package:flutter/material.dart';

import 'pointy_colors.dart';
import 'pointy_theme_extensions.dart';

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

  /// Hover/focus/pressed feedback for controls, tinted by the surface's [ink]
  /// colour so the overlay reads correctly on both light and dark surfaces.
  /// POS terminals run with a mouse, so hover states matter as much as ripples.
  static WidgetStateProperty<Color?> inkOverlay(Color ink) {
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return ink.withValues(alpha: 0.10);
      }
      if (states.contains(WidgetState.hovered)) {
        return ink.withValues(alpha: 0.04);
      }
      if (states.contains(WidgetState.focused)) {
        return ink.withValues(alpha: 0.08);
      }
      return null;
    });
  }

  /// Feedback for controls on the primary green fill. White in both themes
  /// because the primary fill stays brand teal regardless of mode.
  static WidgetStateProperty<Color?> get onPrimaryOverlay {
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return Colors.white.withValues(alpha: 0.16);
      }
      if (states.contains(WidgetState.hovered)) {
        return Colors.white.withValues(alpha: 0.08);
      }
      if (states.contains(WidgetState.focused)) {
        return Colors.white.withValues(alpha: 0.12);
      }
      return null;
    });
  }

  static RoundedRectangleBorder shape(double radius) {
    return RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
  }

  static RoundedRectangleBorder outlinedShape(double radius, [Color? line]) {
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: line == null ? defaultBorder : BorderSide(color: line),
    );
  }

  static AppBarThemeData appBarTheme(
    PointySemanticColors c,
    TextTheme textTheme,
  ) {
    return AppBarThemeData(
      backgroundColor: c.page,
      foregroundColor: c.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: c.ink,
        fontWeight: FontWeight.w700,
      ),
      iconTheme: IconThemeData(color: c.ink),
      actionsIconTheme: IconThemeData(color: c.ink),
    );
  }

  /// Fixed dark top bar for high-focus screens (e.g. POS). Intentionally the
  /// same in light and dark themes, so it stays separate from the palette.
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
        fontSize: 24,
        fontWeight: FontWeight.w700,
      ),
      iconTheme: const IconThemeData(color: PointyColors.surface),
      actionsIconTheme: const IconThemeData(color: PointyColors.surface),
    );
  }

  static InputDecorationThemeData inputDecorationTheme(
    PointySemanticColors c,
    TextTheme textTheme,
  ) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(PointyRadii.input),
      borderSide: BorderSide(color: c.line),
    );

    return InputDecorationThemeData(
      filled: true,
      fillColor: c.surface,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: c.primary, width: 1.4),
      ),
      errorBorder: border.copyWith(
        borderSide: BorderSide(color: c.danger),
      ),
      focusedErrorBorder: border.copyWith(
        borderSide: BorderSide(color: c.danger, width: 1.4),
      ),
      contentPadding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 14),
      labelStyle: textTheme.bodyMedium?.copyWith(color: c.mutedInk),
      hintStyle: textTheme.bodyMedium?.copyWith(color: c.mutedInk),
      helperStyle: textTheme.bodySmall?.copyWith(color: c.mutedInk),
      errorStyle: textTheme.bodySmall?.copyWith(color: c.danger),
      prefixIconColor: c.mutedInk,
      suffixIconColor: c.mutedInk,
    );
  }

  static FilledButtonThemeData filledButtonTheme(
    PointySemanticColors c,
    ColorScheme colorScheme,
  ) {
    return FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, PointyDimensions.buttonHeight),
        backgroundColor: c.primary,
        foregroundColor: colorScheme.onPrimary,
        disabledBackgroundColor: c.line,
        disabledForegroundColor: c.mutedInk,
        shape: shape(PointyRadii.button),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ).copyWith(overlayColor: onPrimaryOverlay),
    );
  }

  static OutlinedButtonThemeData outlinedButtonTheme(
    PointySemanticColors c,
    ColorScheme colorScheme,
  ) {
    return OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, PointyDimensions.buttonHeight),
        foregroundColor: c.primaryStrong,
        disabledForegroundColor: c.mutedInk,
        side: BorderSide(color: c.line),
        shape: shape(PointyRadii.button),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ).copyWith(overlayColor: inkOverlay(c.ink)),
    );
  }

  static TextButtonThemeData textButtonTheme(PointySemanticColors c) {
    return TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, PointyDimensions.buttonHeight),
        foregroundColor: c.primaryStrong,
        disabledForegroundColor: c.mutedInk,
        shape: shape(PointyRadii.button),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ).copyWith(overlayColor: inkOverlay(c.ink)),
    );
  }

  static IconButtonThemeData iconButtonTheme(PointySemanticColors c) {
    return IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size.square(PointyDimensions.iconButton),
        foregroundColor: c.ink,
        disabledForegroundColor: c.mutedInk,
        shape: shape(PointyRadii.button),
      ).copyWith(overlayColor: inkOverlay(c.ink)),
    );
  }

  static ChipThemeData chipTheme(PointySemanticColors c, TextTheme textTheme) {
    return ChipThemeData(
      backgroundColor: c.subtleFill,
      selectedColor: c.primaryContainer,
      disabledColor: c.line,
      surfaceTintColor: Colors.transparent,
      side: BorderSide(color: c.line),
      shape: shape(PointyRadii.chip),
      labelStyle: textTheme.labelLarge?.copyWith(color: c.ink),
      secondaryLabelStyle: textTheme.labelLarge?.copyWith(
        color: c.primaryStrong,
        fontWeight: FontWeight.w600,
      ),
      iconTheme: IconThemeData(color: c.primaryStrong),
      padding: const EdgeInsets.symmetric(horizontal: 8),
    );
  }

  static NavigationDrawerThemeData navigationDrawerTheme(
    PointySemanticColors c,
    TextTheme textTheme,
  ) {
    return NavigationDrawerThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: c.primaryContainer,
      indicatorShape: shape(PointyRadii.button),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final isSelected = states.contains(WidgetState.selected);
        return textTheme.labelLarge?.copyWith(
          color: isSelected ? c.primaryDark : c.ink,
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final isSelected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: isSelected ? c.primaryDark : c.mutedInk,
        );
      }),
    );
  }
}
