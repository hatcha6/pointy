import 'package:flutter/services.dart';

/// Loads the app's real Arabic font into a widget test, so text is measured
/// the way the till draws it. Without it a test falls back to a test font
/// whose letters are all one em wide — roughly twice the width of Arabic
/// script — and reports overflows no cashier would ever see.
///
/// Call from `setUpAll`.
Future<void> loadAppFonts() async {
  for (final family in const ['IBMPlexSansArabic', 'Roboto']) {
    final loader = FontLoader(family);
    for (final weight in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(
        rootBundle.load('assets/fonts/IBMPlexSansArabic-$weight.ttf'),
      );
    }
    await loader.load();
  }
}
