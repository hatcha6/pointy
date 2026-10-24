/// Search that forgives how people type Arabic: hamza forms of alef, taa
/// marbuta, alef maqsura, diacritics and tatweel all fold to one letter, and
/// Latin is case-blind. "ببجي", "ليبيانا" and "LIBYANA" find what they mean.
String foldForSearch(String text) {
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    switch (rune) {
      case 0x0623 || 0x0625 || 0x0622 || 0x0671: // أ إ آ ٱ
        buffer.writeCharCode(0x0627); // ا
      case 0x0629: // ة
        buffer.writeCharCode(0x0647); // ه
      case 0x0649: // ى
        buffer.writeCharCode(0x064A); // ي
      case 0x0624: // ؤ
        buffer.writeCharCode(0x0648); // و
      case 0x0626: // ئ
        buffer.writeCharCode(0x064A); // ي
      case 0x0640: // tatweel
        break;
      default:
        if (rune >= 0x064B && rune <= 0x0652) {
          break; // diacritics
        }
        if (rune >= 0x0660 && rune <= 0x0669) {
          buffer.writeCharCode(0x30 + rune - 0x0660); // Arabic-Indic digits
          break;
        }
        buffer.writeCharCode(rune);
    }
  }
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Whether every word of [query] appears in one of [fields].
bool matchesSearch(String query, Iterable<String> fields) {
  final words = foldForSearch(query).split(' ').where((w) => w.isNotEmpty);
  if (words.isEmpty) {
    return true;
  }
  final haystack = fields.map(foldForSearch).join(' ');
  return words.every(haystack.contains);
}
