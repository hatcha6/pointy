import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/services_fixtures.dart';
import 'package:pointy_frontend/src/data/models/services_directory.dart';
import 'package:pointy_frontend/src/features/pos/direct_services/arabic_search_text.dart';
import 'package:pointy_frontend/src/features/pos/direct_services/country_search.dart';

/// The country picker's brain. A cashier who knows the calling code types it;
/// one who does not types the name, in whatever spelling comes to hand — and a
/// country the services do not reach is still answered, never "no results".
void main() {
  late ServicesDirectory directory;
  late CountrySearch search;

  setUp(() {
    directory = servicesPreviewDirectory();
    search = CountrySearch(
      countries: directory.countries,
      unsupported: directory.unsupported,
      popular: directory.popular,
    );
  });

  List<String> codes(CountrySearchResult result) => [
    for (final match in result.matches) match.country.code,
  ];

  group('by calling code', () {
    test('digits that are a calling code find that country', () {
      final result = search.search('223');
      expect(codes(result), ['ML']);
      expect(result.matches.single.kind, CountryMatchKind.dialExact);
      expect(result.matches.single.dial, '223');
      expect(result.isDialQuery, isTrue);
      expect(result.best?.code, 'ML');
    });

    test('1 is the United States and Canada, then the Caribbean ones', () {
      final result = search.search('1');
      expect(codes(result), ['US', 'CA', 'TT']);
      expect(result.matches.first.kind, CountryMatchKind.dialExact);
      expect(result.matches.last.kind, CountryMatchKind.dialLeadsTo);
      // Two countries share it: Enter must not pick one for the cashier.
      expect(result.best, isNull);
    });

    test('the longest calling code that fits comes first', () {
      final result = search.search('1868');
      expect(codes(result), ['TT', 'US', 'CA']);
      expect(result.matches.first.kind, CountryMatchKind.dialExact);
      expect(result.matches[1].kind, CountryMatchKind.dialPrefixOfInput);
      expect(result.best?.code, 'TT');
    });

    test('digits that only lead to a calling code list every country', () {
      final result = search.search('22');
      expect(codes(result).toSet(), {'ML', 'NE', 'SN', 'CI', 'BF', 'TG', 'BJ'});
      // Popular ones first, in the company\'s order, then by name.
      expect(codes(result).take(2), ['NE', 'ML']);
      expect(
        result.matches.every((m) => m.kind == CountryMatchKind.dialLeadsTo),
        isTrue,
      );
      expect(result.best, isNull);
    });

    test('a whole number pasted into the box finds its country', () {
      expect(codes(search.search('+223 70 12 34 56')), ['ML']);
      expect(codes(search.search('+22370123456')), ['ML']);
      expect(codes(search.search('0022370123456')), ['ML']);
      expect(search.search('+223 70 12 34 56').best?.code, 'ML');
    });

    test('a leading + or 00 is how a number starts, not part of the code', () {
      expect(codes(search.search('+223')), ['ML']);
      expect(codes(search.search('00223')), ['ML']);
      expect(search.search('+').isEmpty, isTrue);
      expect(search.search('00').isEmpty, isTrue);
    });

    test('Arabic-Indic and Persian digits are digits', () {
      expect(codes(search.search('٢٢٣')), ['ML']);
      expect(codes(search.search('۲۲۷')), ['NE']);
    });

    test('nothing in the directory has the code: no country, no crash', () {
      final result = search.search('999');
      expect(result.matches, isEmpty);
      expect(result.hasNoAnswer, isTrue);
    });
  });

  group('by name', () {
    test('finds a country by its Arabic name', () {
      expect(codes(search.search('مالي')), ['ML']);
      expect(codes(search.search('نيجيريا')), ['NG']);
    });

    test('a name that starts with it comes before one that merely has it', () {
      expect(codes(search.search('نيج')), ['NG', 'NE']);
    });

    test('folds hamza, ta marbuta and ya the way Arabic is really typed', () {
      expect(codes(search.search('الامارات')), ['AE']);
      expect(codes(search.search('الإمارات')), ['AE']);
      expect(codes(search.search('امارات')), ['AE']);
      expect(codes(search.search('الاردن')), ['JO']);
      expect(codes(search.search('المملكه المتحده')), ['GB']);
      expect(codes(search.search('المملكة المتحدة')), ['GB']);
    });

    test('ignores tashkeel and tatweel', () {
      expect(codes(search.search('مِصْر')), ['EG']);
      expect(codes(search.search('مـــصر')), ['EG']);
    });

    test('also finds a country by its name in Latin letters or its code', () {
      expect(codes(search.search('mali')), ['ML']);
      expect(codes(search.search('Nigeria')), ['NG']);
      expect(codes(search.search('ML')), ['ML']);
      expect(codes(search.search('ml')), ['ML']);
      expect(codes(search.search('trinidad')), ['TT']);
    });

    test('every word must be found', () {
      expect(codes(search.search('جنوب افريقيا')), ['ZA']);
      expect(codes(search.search('جنوب أفريقيا')), ['ZA']);
      expect(codes(search.search('جنوب مالي')), isEmpty);
      expect(codes(search.search('united states')), ['US']);
    });

    test('a single matching country is what Enter picks', () {
      expect(search.search('مالي').best?.code, 'ML');
      expect(search.search('ن').best, isNull, reason: 'many match');
    });
  });

  group('countries the services do not reach', () {
    test('are answered by name, apart from the ones that are served', () {
      final result = search.search('السودان');
      expect(result.matches, isEmpty);
      expect(result.unsupported.map((country) => country.code), ['SD']);
      expect(result.hasNoAnswer, isFalse);
      expect(search.search('sudan').unsupported.single.code, 'SD');
      expect(search.search('ليبيا').unsupported.single.code, 'LY');
    });

    test('are never listed for a calling code, which they do not have', () {
      expect(search.search('218').unsupported, isEmpty);
    });
  });

  group('browsing with nothing typed', () {
    test('the popular countries come in the company\'s order', () {
      expect(search.popularCountries.map((country) => country.code), [
        'NE',
        'ML',
        'NG',
        'EG',
        'TN',
        'GH',
        'SN',
        'TR',
        'BD',
        'PK',
        'IN',
        'PH',
      ]);
    });

    test('the whole list is A to Z by name, the article not counting', () {
      expect(search.alphabetical, hasLength(directory.countries.length));
      String keyOf(ServiceCountry country) {
        final name = country.name.trim();
        return normalizeSearchText(
          name.startsWith('\u{0627}\u{0644}') && name.length > 2
              ? name.substring(2)
              : name,
        );
      }

      final keys = [for (final country in search.alphabetical) keyOf(country)];
      expect(keys, [...keys]..sort());
    });

    test('«السنغال» is found under س and «ألبانيا»-like names under ا', () {
      final countries = [
        const ServiceCountry(code: 'SN', name: 'السنغال'),
        const ServiceCountry(code: 'ZA', name: 'جنوب أفريقيا'),
        const ServiceCountry(code: 'ML', name: 'مالي'),
        const ServiceCountry(code: 'AL', name: 'ألبانيا'),
        const ServiceCountry(code: 'IN', name: 'الهند'),
        const ServiceCountry(code: 'EG', name: 'مصر'),
        const ServiceCountry(code: 'SD', name: 'السودان'),
      ];

      final order = CountrySearch(countries: countries).alphabetical;

      expect(order.map((country) => country.code), [
        'AL', // ألبانيا
        'ZA', // جنوب أفريقيا
        'SN', // (ال)سنغال — ن before و
        'SD', // (ال)سودان
        'ML', // مالي
        'EG', // مصر
        'IN', // (ال)هند
      ]);
    });

    test('a popular code the directory does not list is skipped', () {
      final narrowed = CountrySearch(
        countries: directory.countries.where((c) => c.code != 'NE'),
        popular: const ['NE', 'ML'],
      );
      expect(narrowed.popularCountries.map((c) => c.code), ['ML']);
    });
  });

  group('which country a number belongs to', () {
    test('is the longest calling code the digits begin with', () {
      expect(search.countryOfNumber('22370123456')?.code, 'ML');
      expect(search.countryOfNumber('18681234567')?.code, 'TT');
      expect(search.countryOfNumber('12125551234')?.code, anyOf('US', 'CA'));
    });

    test('a shared calling code goes to the country already picked', () {
      expect(search.countryOfNumber('12125551234', prefer: 'CA')?.code, 'CA');
      expect(search.countryOfNumber('12125551234', prefer: 'US')?.code, 'US');
    });

    test('is not a country when the digits are only its calling code', () {
      expect(search.countryOfNumber('223'), isNull);
      expect(search.countryOfNumber('9999999999'), isNull);
    });
  });

  group('text normalisation', () {
    test('reduces look-alike letters and strips marks', () {
      expect(normalizeSearchText('أإآ'), 'ااا');
      expect(normalizeSearchText('مدرسة'), 'مدرسه');
      expect(normalizeSearchText('على'), 'علي');
      expect(normalizeSearchText('مُحَمَّد'), 'محمد');
      expect(normalizeSearchText('  Orange   MALI '), 'orange mali');
      expect(normalizeSearchText('\u{2066}Orange\u{2069}'), 'orange');
    });

    test('digits become ASCII', () {
      expect(asciiDigits('٠١٢٣٤٥٦٧٨٩'), '0123456789');
      expect(asciiDigits('۰۱۲۳۴۵۶۷۸۹'), '0123456789');
      expect(digitsOnly('+٢٢٣ 70-12'), '2237012');
    });
  });
}
