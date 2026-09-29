/// How the app reads text it searches on the device: the folding rule the
/// backend applies before it compares (`apps/catalog/search_text.fold`),
/// written a third time.
///
/// Neither side of a search is spelled consistently: a shop writes rice «أرز»
/// in one name and «ارز» in another, ends the same word in «ة» or «ه», glues a
/// size onto a name («كاتشب575»), and nobody types hamza on a till keyboard.
/// Folding BOTH sides the same way before comparing is what makes those the
/// same word — and folding them the way the server does keeps a list filtered
/// here agreeing with a search the server answers.
///
/// One step of the server's rule is missing: Dart has no NFKC. The one effect
/// of it a shop is likely to meet, the lam-alef ligature, is folded by hand;
/// the rest (presentation forms pasted from a PDF, full-width digits) is not.
library;

/// Folds [value] into the form search compares: lower case, marks dropped,
/// letter variants and both Arabic digit sets made one, punctuation turned
/// into spaces, a number split from a word it was glued to
/// (`كاتشب575` -> `كاتشب 575`), spaces collapsed.
///
/// «.», «,» and «/» survive only between two digits, where they belong to the
/// number (`1.5`, `1,000`, `1/4`).
String foldSearchText(String value) {
  if (value.isEmpty) {
    return '';
  }
  final buffer = StringBuffer();
  for (final rune in value.toLowerCase().runes) {
    if (_isDropped(rune)) {
      continue;
    }
    if (rune >= 0x0660 && rune <= 0x0669) {
      buffer.writeCharCode(0x30 + rune - 0x0660);
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      buffer.writeCharCode(0x30 + rune - 0x06F0);
    } else if (rune >= 0xFEF5 && rune <= 0xFEFC) {
      // ﻵ ﻷ ﻹ ﻻ and their final forms: what NFKC would make «لآ» «لأ» «لإ»
      // «لا», which the alef fold then makes one.
      buffer.write('لا');
    } else if (_letterFolds[rune] case final folded?) {
      buffer.write(folded);
    } else if (_punctuation.contains(rune)) {
      buffer.write(' ');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer
      .toString()
      .replaceAll(_looseSeparator, ' ')
      .replaceAllMapped(_digitThenLetter, (match) => '${match[1]} ${match[2]}')
      .replaceAllMapped(_letterThenDigit, (match) => '${match[1]} ${match[2]}')
      .replaceAll(_spaces, ' ')
      .trim();
}

/// The folded words of [value], in order, without repeats.
List<String> searchTokens(String value) {
  return [
    ...{
      for (final word in foldSearchText(value).split(' '))
        if (word.isNotEmpty) word,
    },
  ];
}

/// Marks nobody types consistently. Dropped outright, not turned into a
/// space, so «Kellogg's» reads «kelloggs» and «مُعَلَّبات» reads «معلبات».
bool _isDropped(int rune) {
  return (rune >= 0x0610 && rune <= 0x061A) || // Quranic annotation signs
      (rune >= 0x064B && rune <= 0x065F) || // harakat
      rune == 0x0670 || // superscript alef
      (rune >= 0x06D6 && rune <= 0x06ED) || // Quranic small high signs
      rune == 0x0640 || // tatweel
      // Zero-width and direction controls that ride along with copied text.
      (rune >= 0x200B && rune <= 0x200F) ||
      (rune >= 0x202A && rune <= 0x202E) ||
      (rune >= 0x2066 && rune <= 0x2069) ||
      rune == 0xFEFF ||
      // Apostrophes: ' ’ ‘ ` ´
      rune == 0x0027 ||
      rune == 0x2019 ||
      rune == 0x2018 ||
      rune == 0x0060 ||
      rune == 0x00B4;
}

/// Letter forms that are the same letter to a shop. «ک» and «ی» are the
/// Persian kaf and yeh some keyboards produce. The Arabic decimal point,
/// thousands mark and comma become their ASCII selves, so a number reads the
/// same whichever keyboard typed it.
const Map<int, String> _letterFolds = {
  0x0623: 'ا', // أ
  0x0625: 'ا', // إ
  0x0622: 'ا', // آ
  0x0671: 'ا', // ٱ
  0x0649: 'ي', // ى
  0x0626: 'ي', // ئ
  0x06CC: 'ي', // ی
  0x0624: 'و', // ؤ
  0x0629: 'ه', // ة
  0x06C0: 'ه', // ۀ
  0x06A9: 'ك', // ک
  0x066B: '.', // ٫
  0x066C: ',', // ٬
  0x060C: ',', // ،
};

/// Punctuation that separates words. «.», «,» and «/» are handled by
/// [_looseSeparator], because inside a number they are part of it.
final Set<int> _punctuation = r'!"#$%&()*+:;<=>?@[\]^_{|}~-«»؛؟٪٭“”–—…•·'.runes
    .toSet();

final RegExp _looseSeparator = RegExp(r'(?<![0-9])[.,/]|[.,/](?![0-9])');
final RegExp _digitThenLetter = RegExp(r'([0-9])([^0-9\s.,/])');
final RegExp _letterThenDigit = RegExp(r'([^0-9\s.,/])([0-9])');
final RegExp _spaces = RegExp(r'\s+');
