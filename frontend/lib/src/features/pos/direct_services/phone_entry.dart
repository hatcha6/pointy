/// A phone number as a cashier types it, pastes it, reads it back to the
/// customer and sends it on.
///
/// Pure, and built on the directory's calling codes alone — the app carries no
/// phone-number library, and the relay normalises authoritatively. This only
/// recognises where the country ends and the number begins, so a pasted
/// `+223 70 12 34 56` picks Mali by itself.
library;

import '../../../data/models/services_directory.dart';
import 'arabic_search_text.dart';
import 'country_search.dart';

/// What a typed or pasted number turned out to be.
class PhoneParse {
  const PhoneParse({
    required this.national,
    this.country,
    this.international = false,
    this.candidates = const [],
    this.sharedDial = '',
  });

  /// The digits after the country's calling code (or all the digits, when the
  /// input named no country).
  final String national;

  /// The country the input named by its calling code; null for a number typed
  /// without one.
  final ServiceCountry? country;

  /// The input began with `+` or `00`.
  final bool international;

  /// The countries that share the calling code the input named, when it named
  /// one that more than one country has and nothing settled which (`+1`).
  /// Empty otherwise; [country] is then null, and [national] is what follows
  /// the shared code ([sharedDial]).
  final List<ServiceCountry> candidates;
  final String sharedDial;

  /// The calling code is shared by several countries and the cashier has to
  /// say which one this number is for.
  bool get isSharedCode => candidates.isNotEmpty;

  /// An international number whose calling code no country in the directory
  /// has.
  bool get isUnknownPrefix =>
      international && country == null && candidates.isEmpty;
}

abstract final class PhoneEntry {
  /// The fewest digits a national number can plausibly have.
  static const int minNationalDigits = 6;

  /// E.164 allows 15 digits in all, calling code included.
  static const int maxTotalDigits = 15;

  /// [raw] as the digits and the plus a number is made of.
  ///
  /// A number copied from a chat, a contact card or a receipt arrives dressed:
  /// direction marks around it (WhatsApp wraps every number in them), no-break
  /// and thin spaces, brackets, dots, dashes of every kind — and a `+` that is
  /// then no longer the first character of the text. All of that is dropped,
  /// Arabic digits become ASCII and a full-width `＋` a plain `+`, so what is
  /// left starts with `+` or `00` exactly when the number is international.
  static String cleanInput(String raw) {
    final buffer = StringBuffer();
    for (final rune in asciiDigits(raw).runes) {
      if (_isNoise(rune)) {
        continue;
      }
      buffer.writeCharCode(rune == 0xFF0B ? 0x2B : rune);
    }
    return buffer.toString();
  }

  static bool _isNoise(int rune) =>
      rune == 0x20 ||
      (rune >= 0x09 && rune <= 0x0D) ||
      rune == 0xA0 ||
      rune == 0x61C || // Arabic letter mark
      (rune >= 0x2000 && rune <= 0x200F) || // spaces, zero-width, LRM/RLM
      (rune >= 0x2010 && rune <= 0x2015) || // dashes
      (rune >= 0x202A && rune <= 0x202F) || // embeddings, narrow no-break space
      rune == 0x205F ||
      (rune >= 0x2066 && rune <= 0x2069) || // isolates
      rune == 0x2212 || // minus sign
      rune == 0x3000 ||
      rune == 0xFEFF ||
      const {0x2D, 0x2E, 0x28, 0x29, 0x5B, 0x5D, 0x2F, 0xB7}.contains(rune);

  /// Whether [raw] starts the way an international number does: a `+` or a
  /// `00`, however the number was wrapped on its way here.
  static bool looksInternational(String raw) {
    final text = cleanInput(raw);
    return text.startsWith('+') ||
        (text.startsWith('00') && digitsOnly(text).length > 2);
  }

  /// [raw] read as a number: its digits split into a country (named by the
  /// calling code, when the input has one) and the national number.
  ///
  /// [current] is the country already picked: it settles a calling code that
  /// two countries share (`+1`), and lets a number pasted with its own code
  /// but no `+` still be recognised.
  static PhoneParse parse(
    String raw, {
    required CountrySearch directory,
    ServiceCountry? current,
  }) {
    final digits = digitsOnly(raw);
    if (looksInternational(raw)) {
      final international = cleanInput(raw).startsWith('+')
          ? digits
          : digits.substring(2);
      final matches = directory.countriesOfNumber(international);
      if (matches.isEmpty) {
        return PhoneParse(national: international, international: true);
      }
      // One country has the code, or the country already picked is one of
      // those that share it; otherwise it is the cashier's to say — the first
      // of them in the directory's order is never a good enough answer for a
      // number that is about to receive money.
      ServiceCountry? settled = matches.length == 1 ? matches.first : null;
      if (settled == null && current != null) {
        for (final candidate in matches) {
          if (candidate.code == current.code) {
            settled = candidate;
          }
        }
      }
      if (settled == null) {
        final dial = _longestDial(matches.first, international)!;
        return PhoneParse(
          national: international.substring(dial.length),
          international: true,
          candidates: matches,
          sharedDial: dial,
        );
      }
      final dial = _longestDial(settled, international)!;
      return PhoneParse(
        national: international.substring(dial.length),
        country: settled,
        international: true,
      );
    }
    // A number pasted with its own country's code but no `+`: only believed
    // when what is left is a whole number, so a national number that merely
    // starts with the same digits is never cut.
    if (current != null) {
      final dial = _longestDial(current, digits);
      if (dial != null &&
          digits.length >= 10 &&
          digits.length - dial.length >= 7) {
        return PhoneParse(
          national: digits.substring(dial.length),
          country: current,
          international: true,
        );
      }
    }
    return PhoneParse(national: digits);
  }

  /// [national] in pairs from the left — `70 12 34 56` — stable while it is
  /// typed: a digit added never regroups the ones before it. The ends are
  /// short groups, not a regrouping.
  static String groupNational(String national) {
    final digits = digitsOnly(national);
    final groups = <String>[];
    for (var start = 0; start < digits.length; start += 2) {
      groups.add(
        digits.substring(
          start,
          start + 2 > digits.length ? digits.length : start + 2,
        ),
      );
    }
    return groups.join(' ');
  }

  /// `+223 70 12 34 56`, for the screen. Left to right: wrap it in
  /// `ltrIsolated` inside an Arabic line.
  static String display({required String dial, required String national}) {
    final grouped = groupNational(national);
    final code = digitsOnly(dial);
    if (code.isEmpty) {
      return grouped;
    }
    return grouped.isEmpty ? '+$code' : '+$code $grouped';
  }

  /// [e164] — a number as the server wrote it, `+22370123456` — grouped by its
  /// calling code for the screen: `+223 70 12 34 56`. The code is the one of
  /// [country] when the number begins with it, else the one of whichever
  /// country in [directory] the digits name; a number neither can place is
  /// shown whole.
  static String displayE164(
    String e164, {
    ServiceCountry? country,
    CountrySearch? directory,
  }) {
    final digits = digitsOnly(e164);
    if (digits.isEmpty) {
      return '';
    }
    final named = country == null
        ? null
        : CountrySearch.dialOf(country, digits);
    final owner = named == null && directory != null
        ? directory.countryOfNumber(digits, prefer: country?.code)
        : country;
    final dial =
        named ?? (owner == null ? null : CountrySearch.dialOf(owner, digits));
    if (dial == null || digits.length <= dial.length) {
      return '+$digits';
    }
    return display(dial: dial, national: digits.substring(dial.length));
  }

  /// `+22370123456`: the calling code and the national digits, with the
  /// national trunk `0` dropped when what remains is still a whole number.
  /// A display-time guess: the server answers with the number it normalised,
  /// and that is what the cart line carries.
  static String e164({
    required String dial,
    required String national,
    bool stripTrunkZero = true,
  }) {
    var digits = digitsOnly(national);
    if (stripTrunkZero &&
        digits.startsWith('0') &&
        digits.length - 1 >= minNationalDigits) {
      digits = digits.substring(1);
    }
    return '+${digitsOnly(dial)}$digits';
  }

  /// Whether [national] has enough digits to be tried, and not more than a
  /// number can have beside [dial].
  static bool isPlausible({required String dial, required String national}) {
    final digits = digitsOnly(national);
    return digits.length >= minNationalDigits &&
        !isTooLong(dial: dial, national: national);
  }

  /// More digits than a number can have beside [dial] (one more than E.164's
  /// fifteen is allowed: a trunk zero is dropped before the number is sent).
  static bool isTooLong({required String dial, required String national}) =>
      digitsOnly(national).length + digitsOnly(dial).length >
      maxTotalDigits + 1;

  static String? _longestDial(ServiceCountry country, String digits) =>
      CountrySearch.dialOf(country, digits);
}
