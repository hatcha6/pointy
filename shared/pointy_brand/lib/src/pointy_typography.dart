import 'package:flutter/material.dart';

/// Arabic-first type system for the Daftar apps.
///
/// IBM Plex Sans Arabic ships inside this package so every app renders it
/// identically offline. The ramp removes Material's positive letter spacing
/// (which visually breaks connected Arabic script) and raises line heights so
/// Arabic ascenders and diacritics do not clip.
abstract final class PointyTypography {
  /// The family as an app that depends on this package names it.
  static const String fontFamily = 'IBMPlexSansArabic';
  static const String fontPackage = 'pointy_brand';

  static const double _displayHeight = 1.2;
  static const double _headlineHeight = 1.25;
  static const double _titleHeight = 1.3;
  static const double _bodyHeight = 1.5;
  static const double _labelHeight = 1.45;

  static TextTheme textTheme(TextTheme base) {
    TextStyle? tune(TextStyle? style, double height) {
      return style?.copyWith(
        fontFamily: 'packages/$fontPackage/$fontFamily',
        letterSpacing: 0,
        height: height,
      );
    }

    return TextTheme(
      displayLarge: tune(base.displayLarge, _displayHeight),
      displayMedium: tune(base.displayMedium, _displayHeight),
      displaySmall: tune(base.displaySmall, _displayHeight),
      headlineLarge: tune(base.headlineLarge, _headlineHeight),
      headlineMedium: tune(base.headlineMedium, _headlineHeight),
      headlineSmall: tune(base.headlineSmall, _headlineHeight),
      titleLarge: tune(base.titleLarge, _titleHeight),
      titleMedium: tune(base.titleMedium, _titleHeight),
      titleSmall: tune(base.titleSmall, _titleHeight),
      bodyLarge: tune(base.bodyLarge, _bodyHeight),
      bodyMedium: tune(base.bodyMedium, _bodyHeight),
      bodySmall: tune(base.bodySmall, _bodyHeight),
      labelLarge: tune(base.labelLarge, _labelHeight),
      labelMedium: tune(base.labelMedium, _labelHeight),
      labelSmall: tune(base.labelSmall, _labelHeight),
    );
  }

  /// Style for amounts, quantities and codes: tabular figures keep digits the
  /// same width so numbers align and do not jitter when values change.
  static TextStyle numeric(TextStyle style) {
    return style.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
  }
}
