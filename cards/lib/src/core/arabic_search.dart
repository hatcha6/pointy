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
  return buffer.toString().replaceAll(_spaces, ' ').trim();
}

final _spaces = RegExp(r'\s+');

/// Whether every word of [query] appears in one of [fields].
bool matchesSearch(String query, Iterable<String> fields) {
  final words = searchWords(query);
  if (words.isEmpty) {
    return true;
  }
  return matchesWords(words, searchText(fields));
}

/// The words of [query], folded: what a search looks for.
List<String> searchWords(String query) => [
  for (final word in foldForSearch(query).split(' '))
    if (word.isNotEmpty) word,
];

/// [fields] folded into one text to search, worked out once for something
/// searched many times (a brand at every letter typed).
String searchText(Iterable<String> fields) =>
    fields.map(foldForSearch).join(' ');

/// Whether every one of [words] (from [searchWords]) appears in [text] (from
/// [searchText]).
bool matchesWords(List<String> words, String text) =>
    words.every(text.contains);
