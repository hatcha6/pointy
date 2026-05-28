import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() {
  group('PointyColors', () {
    test('keeps design guide token values stable', () {
      expect(PointyColors.primary, const Color(0xFF0F766E));
      expect(PointyColors.primaryStrong, const Color(0xFF006C53));
      expect(PointyColors.primaryDark, const Color(0xFF064E3B));
      expect(PointyColors.darkTopBar, const Color(0xFF0B111C));
      expect(PointyColors.accentAmber, const Color(0xFFC98A3B));
      expect(PointyColors.danger, const Color(0xFFB42318));
      expect(PointyColors.warning, const Color(0xFFB65F2A));
      expect(PointyColors.success, const Color(0xFF0E6B4E));
      expect(PointyColors.ink, const Color(0xFF101828));
      expect(PointyColors.mutedInk, const Color(0xFF667085));
      expect(PointyColors.line, const Color(0xFFE5E0D8));
      expect(PointyColors.surface, const Color(0xFFFFFFFF));
      expect(PointyColors.page, const Color(0xFFF8F7F4));
    });
  });

  group('PointySemanticColors', () {
    test('is registered on the app theme', () {
      final theme = PointyTheme.light();
      final semanticColors = theme.extension<PointySemanticColors>();

      expect(semanticColors, isNotNull);
      expect(semanticColors?.darkTopBar, PointyColors.darkTopBar);
      expect(semanticColors?.accentAmber, PointyColors.accentAmber);
      expect(semanticColors?.line, PointyColors.line);
    });

    test('copyWith preserves unspecified values', () {
      const colors = PointySemanticColors.light();
      final updated = colors.copyWith(danger: Colors.red);

      expect(updated.danger, Colors.red);
      expect(updated.success, colors.success);
      expect(updated.page, colors.page);
    });

    test('lerp interpolates semantic values', () {
      const colors = PointySemanticColors.light();
      final other = colors.copyWith(ink: Colors.white);

      expect(colors.lerp(other, 0).ink, colors.ink);
      expect(colors.lerp(other, 1).ink, Colors.white);
      expect(
        colors.lerp(other, 0.5).ink,
        Color.lerp(colors.ink, Colors.white, 0.5),
      );
    });
  });

  group('PointyTheme', () {
    test('uses Material 3 and the shared color scheme', () {
      final theme = PointyTheme.light();

      expect(theme.useMaterial3, isTrue);
      expect(theme.scaffoldBackgroundColor, PointyColors.page);
      expect(theme.colorScheme.primary, PointyColors.primary);
      expect(theme.colorScheme.secondary, PointyColors.accentAmber);
      expect(theme.colorScheme.error, PointyColors.danger);
      expect(theme.colorScheme.surface, PointyColors.surface);
      expect(theme.colorScheme.outline, PointyColors.line);
    });

    test('keeps core component dimensions and shapes stable', () {
      final theme = PointyTheme.light();
      final filledStyle = theme.filledButtonTheme.style!;
      final iconStyle = theme.iconButtonTheme.style!;
      final cardShape = theme.cardTheme.shape! as RoundedRectangleBorder;
      final inputBorder =
          theme.inputDecorationTheme.enabledBorder! as OutlineInputBorder;

      expect(
        filledStyle.minimumSize?.resolve(<WidgetState>{}),
        const Size(64, PointyDimensions.buttonHeight),
      );
      expect(
        iconStyle.minimumSize?.resolve(<WidgetState>{}),
        const Size.square(PointyDimensions.iconButton),
      );
      expect(cardShape.borderRadius, BorderRadius.circular(PointyRadii.card));
      expect(
        inputBorder.borderRadius,
        BorderRadius.circular(PointyRadii.input),
      );
      expect(theme.inputDecorationTheme.filled, isTrue);
      expect(theme.inputDecorationTheme.fillColor, PointyColors.surface);
    });

    test('provides a dark app bar helper for high-focus flows', () {
      final theme = PointyTheme.light();
      final darkAppBarTheme = PointyComponentStyles.darkAppBarTheme(
        theme.textTheme,
      );

      expect(darkAppBarTheme.backgroundColor, PointyColors.darkTopBar);
      expect(darkAppBarTheme.foregroundColor, PointyColors.surface);
      expect(darkAppBarTheme.centerTitle, isTrue);
    });
  });
}
