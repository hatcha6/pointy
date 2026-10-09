/// Text as the direct-service search boxes compare it: what a cashier types
/// and what the directory holds are both reduced to the same plain form, so
/// «الإمارات» is found by «الامارات», «مصر» by «مِصْر», «ml» by «ML».
library;

/// Arabic-Indic (٠-٩) and Persian (۰-۹) digits as ASCII; everything else is
/// kept.
String asciiDigits(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      buffer.writeCharCode(0x30 + (rune - 0x0660));
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      buffer.writeCharCode(0x30 + (rune - 0x06F0));
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// Only the digits of [input], as ASCII.
String digitsOnly(String input) =>
    asciiDigits(input).replaceAll(RegExp(r'[^0-9]'), '');

/// [input] reduced for comparison: lower case, ASCII digits, Arabic without
/// its marks (tashkeel, tatweel) and with its look-alike letters folded
/// together — أ إ آ ٱ → ا · ة → ه · ى → ي · ؤ → و · ئ → ي — and every run of
/// spaces, no-break spaces and bidi controls one plain space.
String normalizeSearchText(String input) {
  final buffer = StringBuffer();
  for (final rune in asciiDigits(input).runes) {
    if (_isMark(rune)) {
      continue;
    }
    buffer.writeCharCode(switch (rune) {
      0x0623 || 0x0625 || 0x0622 || 0x0671 => 0x0627, // أ إ آ ٱ → ا
      0x0629 => 0x0647, // ة → ه
      0x0649 => 0x064A, // ى → ي
      0x0624 => 0x0648, // ؤ → و
      0x0626 => 0x064A, // ئ → ي
      0x00A0 ||
      0x200E ||
      0x200F ||
      0x2066 ||
      0x2067 ||
      0x2068 ||
      0x2069 => 0x20,
      final other => other,
    });
  }
  return buffer.toString().toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Tashkeel, the dagger alef, Quranic marks and tatweel.
bool _isMark(int rune) =>
    (rune >= 0x064B && rune <= 0x065F) ||
    rune == 0x0670 ||
    (rune >= 0x06D6 && rune <= 0x06ED) ||
    rune == 0x0640 ||
    (rune >= 0x202A && rune <= 0x202E);
