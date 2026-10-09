/// Finding a country the way a cashier looks for one: by its Arabic name, by
/// its name in Latin letters, by its two-letter code, or — fastest, for the
/// cashier who knows it — by the first digits of its calling code.
///
/// Pure: the directory in, an ordered answer out.
library;

import '../../../data/models/services_directory.dart';
import 'arabic_search_text.dart';

/// Why a country is in an answer.
enum CountryMatchKind {
  /// The digits typed are the country's calling code.
  dialExact,

  /// The digits typed start with the country's calling code: a whole number
  /// was pasted, and this is the country it begins with.
  dialPrefixOfInput,

  /// The digits typed so far lead to the country's calling code.
  dialLeadsTo,

  /// The text typed is in its name or its code.
  text,
}

/// One country in an answer, and the calling code that matched, if one did.
class CountryMatch {
  const CountryMatch(this.country, this.kind, {this.dial = ''});

  final ServiceCountry country;
  final CountryMatchKind kind;

  /// The calling code that matched (digits, no `+`); empty for a text match.
  final String dial;
}

class CountrySearchResult {
  const CountrySearchResult({
    required this.query,
    required this.digits,
    required this.matches,
    required this.unsupported,
  });

  /// What was typed, reduced for comparison (empty for no query).
  final String query;

  /// The digits of a calling-code query; empty when the query is text.
  final String digits;
  final List<CountryMatch> matches;

  /// Countries the services do not serve whose name matched: so a search for
  /// «السودان» never answers "no results".
  final List<UnsupportedServiceCountry> unsupported;

  bool get isEmpty => query.isEmpty && digits.isEmpty;
  bool get isDialQuery => digits.isNotEmpty;
  bool get hasNoAnswer => matches.isEmpty && unsupported.isEmpty;

  List<ServiceCountry> get countries => [
    for (final match in matches) match.country,
  ];

  /// The country Enter should pick: the one country with exactly that calling
  /// code, or the only country that matched. Null when there is nothing to be
  /// sure about — `1` is the United States and Canada, and the cashier says
  /// which.
  ServiceCountry? get best {
    if (matches.isEmpty) {
      return null;
    }
    final first = matches.first;
    if (first.kind == CountryMatchKind.dialExact) {
      final shared =
          matches.length > 1 && matches[1].kind == CountryMatchKind.dialExact;
      return shared ? null : first.country;
    }
    return matches.length == 1 ? first.country : null;
  }
}

class CountrySearch {
  CountrySearch({
    required Iterable<ServiceCountry> countries,
    Iterable<UnsupportedServiceCountry> unsupported = const [],
    Iterable<String> popular = const [],
  }) : countries = List.unmodifiable(countries),
       unsupported = List.unmodifiable(unsupported),
       _popular = List.unmodifiable(popular.map((code) => code.toUpperCase())) {
    _names = {
      for (final country in this.countries)
        country.code: normalizeSearchText(country.name),
    };
    _namesEn = {
      for (final country in this.countries)
        country.code: normalizeSearchText(country.nameEn),
    };
  }

  final List<ServiceCountry> countries;
  final List<UnsupportedServiceCountry> unsupported;
  final List<String> _popular;
  late final Map<String, String> _names;
  late final Map<String, String> _namesEn;

  /// The company's popular countries, in its order.
  late final List<ServiceCountry> popularCountries = () {
    final byCode = {for (final country in countries) country.code: country};
    final listed = <ServiceCountry>[];
    for (final code in _popular) {
      final country = byCode[code];
      if (country != null && !listed.contains(country)) {
        listed.add(country);
      }
    }
    return List<ServiceCountry>.unmodifiable(listed);
  }();

  /// Every country by name, A to Z — the way an Arabic reader looks one up:
  /// the definite article does not count, so «السودان» is under س and
  /// «الهند» under ه, while «ألبانيا» (whose أل is part of the name) stays
  /// under ا.
  late final List<ServiceCountry> alphabetical = () {
    final keys = {
      for (final country in countries) country.code: _sortKey(country.name),
    };
    final sorted = [...countries]
      ..sort((a, b) {
        final byName = keys[a.code]!.compareTo(keys[b.code]!);
        return byName != 0 ? byName : a.code.compareTo(b.code);
      });
    return List<ServiceCountry>.unmodifiable(sorted);
  }();

  /// [name] as a dictionary orders it: without a leading «ال» (a plain alef
  /// then lam, so «أل…» names are left alone), reduced like a search.
  static String _sortKey(String name) {
    final trimmed = name.trim();
    final withoutArticle =
        trimmed.length > 2 && trimmed.startsWith('\u{0627}\u{0644}')
        ? trimmed.substring(2)
        : trimmed;
    return normalizeSearchText(withoutArticle);
  }

  /// [input] as the answer to "which country?".
  CountrySearchResult search(String input) {
    final query = normalizeSearchText(input);
    final stripped = _stripInternationalPrefix(query);
    if (stripped.isEmpty) {
      return const CountrySearchResult(
        query: '',
        digits: '',
        matches: [],
        unsupported: [],
      );
    }
    if (RegExp(r'^[0-9 \-]+$').hasMatch(stripped)) {
      final digits = stripped.replaceAll(RegExp(r'[^0-9]'), '');
      return CountrySearchResult(
        query: query,
        digits: digits,
        matches: _byDial(digits),
        unsupported: const [],
      );
    }
    return CountrySearchResult(
      query: query,
      digits: '',
      matches: _byText(query),
      unsupported: _unsupportedByText(query),
    );
  }

  /// The country whose calling code [digits] begins with, the longest code
  /// first; [prefer] wins among countries that share the code (the United
  /// States and Canada). Null when none does. [digits] must be longer than the
  /// code: a number is more than its country.
  ServiceCountry? countryOfNumber(String digits, {String? prefer}) {
    ServiceCountry? best;
    var bestLength = 0;
    for (final country in countries) {
      for (final dial in country.dial) {
        if (digits.length <= dial.length || !digits.startsWith(dial)) {
          continue;
        }
        final better =
            dial.length > bestLength ||
            (dial.length == bestLength &&
                best != null &&
                country.code == prefer &&
                best.code != prefer);
        if (better) {
          best = country;
          bestLength = dial.length;
        }
      }
    }
    return best;
  }

  /// Every country whose calling code [digits] begins with, at the longest code
  /// any of them has: one country for most codes, several when a code is shared
  /// (`+1` is the United States and Canada). Empty when none matches.
  List<ServiceCountry> countriesOfNumber(String digits) {
    var bestLength = 0;
    final found = <ServiceCountry>[];
    for (final country in countries) {
      for (final dial in country.dial) {
        if (digits.length <= dial.length || !digits.startsWith(dial)) {
          continue;
        }
        if (dial.length > bestLength) {
          bestLength = dial.length;
          found
            ..clear()
            ..add(country);
        } else if (dial.length == bestLength && !found.contains(country)) {
          found.add(country);
        }
      }
    }
    return found;
  }

  /// The calling code of [country] that [digits] begins with, longest first.
  static String? dialOf(ServiceCountry country, String digits) {
    String? found;
    for (final dial in country.dial) {
      if (digits.startsWith(dial) &&
          (found == null || dial.length > found.length)) {
        found = dial;
      }
    }
    return found;
  }

  List<CountryMatch> _byDial(String digits) {
    final ranked = <(double, CountryMatch)>[];
    for (final country in countries) {
      (double, CountryMatch)? best;
      for (final dial in country.dial) {
        final (double, CountryMatch)? candidate;
        if (dial == digits) {
          candidate = (
            0,
            CountryMatch(country, CountryMatchKind.dialExact, dial: dial),
          );
        } else if (digits.startsWith(dial)) {
          // A longer code that fits is the better guess: 1868 over 1.
          candidate = (
            1 + (16 - dial.length) / 100,
            CountryMatch(
              country,
              CountryMatchKind.dialPrefixOfInput,
              dial: dial,
            ),
          );
        } else if (dial.startsWith(digits)) {
          candidate = (
            2 + dial.length / 100,
            CountryMatch(country, CountryMatchKind.dialLeadsTo, dial: dial),
          );
        } else {
          candidate = null;
        }
        if (candidate != null && (best == null || candidate.$1 < best.$1)) {
          best = candidate;
        }
      }
      if (best != null) {
        ranked.add(best);
      }
    }
    ranked.sort((a, b) {
      final byRank = a.$1.compareTo(b.$1);
      if (byRank != 0) return byRank;
      return _byPopularityThenName(a.$2.country, b.$2.country);
    });
    return [for (final entry in ranked) entry.$2];
  }

  List<CountryMatch> _byText(String query) {
    final tokens = query.split(' ');
    final ranked = <(double, ServiceCountry)>[];
    for (final country in countries) {
      final score = _textScore(country, tokens);
      if (score != null) {
        ranked.add((score, country));
      }
    }
    ranked.sort((a, b) {
      final byScore = a.$1.compareTo(b.$1);
      if (byScore != 0) return byScore;
      return _byPopularityThenName(a.$2, b.$2);
    });
    return [
      for (final entry in ranked) CountryMatch(entry.$2, CountryMatchKind.text),
    ];
  }

  /// How well every token of the query is found in the country, lower is
  /// better; null when one is not found at all.
  double? _textScore(ServiceCountry country, List<String> tokens) {
    var total = 0.0;
    for (final token in tokens) {
      final score = _tokenScore(country, token);
      if (score == null) {
        return null;
      }
      total += score;
    }
    return total / tokens.length;
  }

  double? _tokenScore(ServiceCountry country, String token) {
    if (token.isEmpty) {
      return 0;
    }
    double? best;
    void consider(double? score) {
      if (score != null && (best == null || score < best!)) {
        best = score;
      }
    }

    // The two-letter code, typed whole: «ml» is Mali before it is a word.
    if (token.length == 2 && country.code.toLowerCase() == token) {
      consider(0.5);
    }
    consider(_fieldScore(_names[country.code]!, token, 0));
    consider(_fieldScore(_namesEn[country.code]!, token, 0.2));
    return best;
  }

  static double? _fieldScore(String field, String token, double bias) {
    if (field.isEmpty) {
      return null;
    }
    if (field.startsWith(token)) {
      return 1 + bias;
    }
    if (field.contains(' $token')) {
      return 2 + bias;
    }
    if (field.contains(token)) {
      return 3 + bias;
    }
    return null;
  }

  List<UnsupportedServiceCountry> _unsupportedByText(String query) {
    final tokens = query.split(' ');
    final found = <UnsupportedServiceCountry>[];
    for (final country in unsupported) {
      final name = normalizeSearchText(country.name);
      final nameEn = normalizeSearchText(country.nameEn);
      final code = country.code.toLowerCase();
      final matches = tokens.every(
        (token) =>
            (token.length == 2 && code == token) ||
            (name.isNotEmpty && name.contains(token)) ||
            (nameEn.isNotEmpty && nameEn.contains(token)),
      );
      if (matches) {
        found.add(country);
      }
    }
    found.sort(
      (a, b) =>
          normalizeSearchText(a.name).compareTo(normalizeSearchText(b.name)),
    );
    return found;
  }

  int _byPopularityThenName(ServiceCountry a, ServiceCountry b) {
    final rankA = _popularPlace(a);
    final rankB = _popularPlace(b);
    if (rankA != rankB) return rankA.compareTo(rankB);
    return _names[a.code]!.compareTo(_names[b.code]!);
  }

  int _popularPlace(ServiceCountry country) {
    final listed = _popular.indexOf(country.code);
    if (listed >= 0) return listed;
    return country.popularRank > 0 ? 1000 + country.popularRank : 1 << 20;
  }

  /// A leading `+` or `00` is how a number starts, not part of a name or a
  /// calling code.
  static String _stripInternationalPrefix(String query) {
    var text = query.trim();
    if (text.startsWith('+')) {
      text = text.substring(1).trim();
    } else if (text.startsWith('00') && RegExp(r'^[0-9 \-]+$').hasMatch(text)) {
      text = text.substring(2).trim();
    }
    return text;
  }
}
