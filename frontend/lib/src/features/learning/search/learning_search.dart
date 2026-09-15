import '../models/learning_guide.dart';

/// Folds a string into the form the learning index and the search box both
/// compare in.
///
/// Arabic typing is far less uniform than the strings we ship: a cashier looking
/// for "آجل" types "اجل", someone after "الاستلام" types "الإستلام", and the
/// numeral keys on a Libyan Android keyboard produce ٠-٩ rather than 0-9. A raw
/// `contains` therefore misses the overwhelming majority of real queries, which
/// is exactly the failure that makes people conclude a search box is broken.
///
/// So we strip what never carries meaning (tashkeel, tatweel, punctuation) and
/// unify the letter forms readers treat as the same letter.
String normalizeSearchText(String input) {
  final buffer = StringBuffer();
  var lastWasSpace = true;

  for (final rune in input.runes) {
    final char = String.fromCharCode(rune);

    // Tashkeel, the dagger alef, and the tatweel elongation: decoration only.
    if ((rune >= 0x064B && rune <= 0x0652) ||
        rune == 0x0670 ||
        rune == 0x0640 ||
        // Quranic annotation marks, which arrive by copy/paste.
        (rune >= 0x06D6 && rune <= 0x06ED)) {
      continue;
    }

    // Arabic-Indic and extended Arabic-Indic digits.
    if (rune >= 0x0660 && rune <= 0x0669) {
      buffer.write(String.fromCharCode(rune - 0x0660 + 0x30));
      lastWasSpace = false;
      continue;
    }
    if (rune >= 0x06F0 && rune <= 0x06F9) {
      buffer.write(String.fromCharCode(rune - 0x06F0 + 0x30));
      lastWasSpace = false;
      continue;
    }

    final folded = switch (char) {
      'أ' || 'إ' || 'آ' || 'ٱ' || 'ٲ' || 'ٳ' => 'ا',
      'ة' => 'ه',
      'ى' || 'ئ' => 'ي',
      'ؤ' => 'و',
      'ك' || 'ڪ' => 'ك',
      'ﻻ' || 'ﻷ' || 'ﻹ' || 'ﻵ' => 'لا',
      _ => char,
    };

    final isLetterOrDigit =
        RegExp(r'[ء-ي0-9a-zA-Z]').hasMatch(folded) || folded == 'لا';
    if (!isLetterOrDigit) {
      // Everything else — spaces, punctuation, «», dashes, emoji — is a break.
      if (!lastWasSpace) {
        buffer.write(' ');
        lastWasSpace = true;
      }
      continue;
    }

    buffer.write(folded.toLowerCase());
    lastWasSpace = false;
  }

  return buffer.toString().trim();
}

/// Splits a normalized string into tokens, dropping the Arabic definite article
/// so "الفاتورة" and "فاتورة" are the same search.
List<String> tokenizeSearchText(String normalized) {
  return [
    for (final raw in normalized.split(' '))
      if (raw.isNotEmpty) _stripArticle(raw),
  ];
}

String _stripArticle(String token) {
  if (token.length > 4 && token.startsWith('ال')) {
    return token.substring(2);
  }
  return token;
}

/// A guide's precomputed search index.
///
/// Built once per library rather than per keystroke: normalizing 60 guides of
/// body copy on every character typed is the kind of thing that makes an
/// otherwise fine search box feel laggy on the 2011 machines these shops run.
class LearningSearchIndex {
  LearningSearchIndex._(this.guideId, this._title, this._keywords, this._body);

  factory LearningSearchIndex.of(LearningGuide guide) {
    return LearningSearchIndex._(
      guide.id,
      tokenizeSearchText(normalizeSearchText(guide.title)),
      tokenizeSearchText(
        normalizeSearchText([guide.summary, ...guide.keywords].join(' ')),
      ),
      tokenizeSearchText(normalizeSearchText(guide.bodyText.join(' '))),
    );
  }

  final String guideId;
  final List<String> _title;
  final List<String> _keywords;
  final List<String> _body;

  /// Score for [queryTokens] — 0 when the guide does not match.
  ///
  /// Every token must appear somewhere (AND, not OR): typing two words narrows
  /// the list, which is what anyone who has used a search box expects. Each
  /// token scores where it hit hardest, so a title match outranks a passing
  /// mention in the body.
  int score(List<String> queryTokens) {
    if (queryTokens.isEmpty) {
      return 0;
    }
    var total = 0;
    for (final token in queryTokens) {
      final hit = _scoreToken(token);
      if (hit == 0) {
        return 0;
      }
      total += hit;
    }
    return total;
  }

  int _scoreToken(String token) {
    if (_matches(_title, token, exactBonus: true) case final score
        when score > 0) {
      return 40 + score;
    }
    if (_matches(_keywords, token, exactBonus: true) case final score
        when score > 0) {
      return 12 + score;
    }
    if (_matches(_body, token) case final score when score > 0) {
      return 2 + score;
    }
    return 0;
  }

  /// A token matches a field when it is a prefix of one of the field's words
  /// (so "فوات" finds "فواتير" mid-typing), or a substring of one of them (so
  /// a typed suffix still lands). Prefixes score above substrings.
  static int _matches(
    List<String> words,
    String token, {
    bool exactBonus = false,
  }) {
    var best = 0;
    for (final word in words) {
      if (word == token) {
        return exactBonus ? 8 : 4;
      }
      if (word.startsWith(token)) {
        best = best < 3 ? 3 : best;
      } else if (token.length >= 3 && word.contains(token)) {
        best = best < 1 ? 1 : best;
      }
    }
    return best;
  }
}
