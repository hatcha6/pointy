import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/services_fixtures.dart';
import 'package:pointy_frontend/src/data/models/services_directory.dart';
import 'package:pointy_frontend/src/features/pos/direct_services/country_search.dart';
import 'package:pointy_frontend/src/features/pos/direct_services/phone_entry.dart';

/// A number as a cashier types it or pastes it from the customer's message.
/// Whatever was typed is never altered unless the country it names is clear.
void main() {
  late ServicesDirectory directory;
  late CountrySearch search;
  late ServiceCountry mali;
  late ServiceCountry nigeria;

  setUp(() {
    directory = servicesPreviewDirectory();
    search = CountrySearch(countries: directory.countries);
    mali = directory.country('ML')!;
    nigeria = directory.country('NG')!;
  });

  PhoneParse parse(String raw, {ServiceCountry? current}) =>
      PhoneEntry.parse(raw, directory: search, current: current);

  group('pasting a whole number', () {
    test('with a plus picks the country by itself', () {
      for (final raw in const [
        '+22370123456',
        '+223 70 12 34 56',
        '+223-70-12-34-56',
        '  +223 70123456  ',
      ]) {
        final result = parse(raw);
        expect(result.country?.code, 'ML', reason: raw);
        expect(result.national, '70123456', reason: raw);
        expect(result.international, isTrue);
      }
    });

    test('with 00 picks the country by itself', () {
      final result = parse('0022370123456');
      expect(result.country?.code, 'ML');
      expect(result.national, '70123456');
      expect(result.international, isTrue);
      expect(parse('00 223 70 12 34 56').national, '70123456');
    });

    test('with Arabic digits reads them as digits', () {
      final result = parse('+٢٢٣ ٧٠ ١٢ ٣٤ ٥٦');
      expect(result.country?.code, 'ML');
      expect(result.national, '70123456');
    });

    test('copied from a chat or a contact card still names its country', () {
      // WhatsApp wraps a number in direction marks; contact cards use brackets,
      // dots and no-break spaces. None of it may hide the plus.
      for (final raw in const [
        '\u202A+223 70 12 34 56\u202C',
        '\u200E+223 70 12 34 56\u200E',
        '\u2066+223 70 12 34 56\u2069',
        '\u202B\u200F+223\u00A070\u00A012\u00A034\u00A056\u202C',
        '(+223) 70 12 34 56',
        '+223 (70) 12-34-56',
        '+223.70.12.34.56',
        '\uFF0B223 70 12 34 56',
        '+223\u202F70\u202F12\u202F34\u202F56',
      ]) {
        final result = parse(raw);
        expect(result.country?.code, 'ML', reason: raw);
        expect(result.national, '70123456', reason: raw);
        expect(result.international, isTrue, reason: raw);
        expect(PhoneEntry.looksInternational(raw), isTrue, reason: raw);
      }
    });

    test('with 00 behind direction marks or brackets is international too', () {
      for (final raw in const [
        '\u202A00223 70 12 34 56\u202C',
        '(00223) 70 12 34 56',
        '٠٠٢٢٣ ٧٠ ١٢ ٣٤ ٥٦',
      ]) {
        final result = parse(raw);
        expect(result.country?.code, 'ML', reason: raw);
        expect(result.national, '70123456', reason: raw);
      }
    });

    test('a national number in brackets is not made international', () {
      expect(PhoneEntry.looksInternational('(70) 12 34 56'), isFalse);
      expect(PhoneEntry.looksInternational('\u202A70 12 34 56\u202C'), isFalse);
    });

    test('switches the country when it is another one', () {
      final result = parse('+2349031234567', current: mali);
      expect(result.country?.code, 'NG');
      expect(result.national, '9031234567');
    });

    test('the longest calling code wins', () {
      final result = parse('+1 868 123 4567');
      expect(result.country?.code, 'TT');
      expect(result.national, '1234567');
    });

    test('a calling code two countries share goes to the one picked', () {
      final canada = directory.country('CA')!;
      expect(parse('+1 212 555 1234', current: canada).country?.code, 'CA');
      expect(
        parse(
          '+1 212 555 1234',
          current: directory.country('US'),
        ).country?.code,
        'US',
      );
    });

    test('a calling code two countries share, with neither picked, is the '
        'cashier\'s to decide', () {
      final result = parse('+1 212 555 1234');

      expect(result.country, isNull, reason: 'never the first of them');
      expect(result.isSharedCode, isTrue);
      expect(result.isUnknownPrefix, isFalse);
      expect(result.international, isTrue);
      expect(result.candidates.map((country) => country.code).toSet(), {
        'US',
        'CA',
      });
      expect(result.national, '2125551234');
    });

    test('and so is it when the country picked is a third one', () {
      final result = parse('+1 212 555 1234', current: mali);

      expect(result.country, isNull);
      expect(result.candidates.map((country) => country.code).toSet(), {
        'US',
        'CA',
      });
    });

    test('a code only one country has is not a question', () {
      final result = parse('+223 70 12 34 56');

      expect(result.country?.code, 'ML');
      expect(result.candidates, isEmpty);
      expect(result.isSharedCode, isFalse);
    });

    test('an unknown calling code is said to be unknown, not guessed', () {
      final result = parse('+999 123 456 789');
      expect(result.country, isNull);
      expect(result.international, isTrue);
      expect(result.isUnknownPrefix, isTrue);
      expect(result.national, '999123456789');
    });
  });

  group('typing a national number', () {
    test('is left exactly as typed', () {
      final result = parse('70123456', current: mali);
      expect(result.national, '70123456');
      expect(result.country, isNull);
      expect(result.international, isFalse);
    });

    test('keeps a leading zero: the relay decides what it means', () {
      expect(parse('070123456', current: mali).national, '070123456');
      expect(parse('08031234567', current: nigeria).national, '08031234567');
    });

    test('drops separators and keeps only digits', () {
      expect(parse('70 12-34 56', current: mali).national, '70123456');
      expect(parse('(70) 12 34 56', current: mali).national, '70123456');
    });

    test('a number pasted with its own calling code but no plus is cut', () {
      final result = parse('22370123456', current: mali);
      expect(result.country?.code, 'ML');
      expect(result.national, '70123456');
      expect(result.international, isTrue);
    });

    test(
      'but a national number that merely begins with the same digits is not',
      () {
        // 9 digits: too short to be dial code + whole number.
        expect(parse('223701234', current: mali).national, '223701234');
        // Another country\'s code is not this country\'s.
        expect(parse('22370123456', current: nigeria).national, '22370123456');
      },
    );
  });

  group('showing a number', () {
    test('groups national digits in pairs from the left, stable as typed', () {
      expect(PhoneEntry.groupNational(''), '');
      expect(PhoneEntry.groupNational('7'), '7');
      expect(PhoneEntry.groupNational('70'), '70');
      expect(PhoneEntry.groupNational('701'), '70 1');
      expect(PhoneEntry.groupNational('7012'), '70 12');
      expect(PhoneEntry.groupNational('70123456'), '70 12 34 56');
      expect(PhoneEntry.groupNational('9031234567'), '90 31 23 45 67');
      // A digit added never regroups the ones before it.
      final grown = ['7', '70', '701', '7012', '70123', '701234'];
      for (var i = 1; i < grown.length; i++) {
        final before = PhoneEntry.groupNational(grown[i - 1]);
        expect(
          PhoneEntry.groupNational(grown[i]).startsWith(before),
          isTrue,
          reason: '${grown[i - 1]} -> ${grown[i]}',
        );
      }
    });

    test('puts the calling code in front', () {
      expect(
        PhoneEntry.display(dial: '223', national: '70123456'),
        '+223 70 12 34 56',
      );
      expect(PhoneEntry.display(dial: '+223', national: ''), '+223');
      expect(PhoneEntry.display(dial: '', national: '7012'), '70 12');
    });
  });

  group('building E.164', () {
    test('joins the calling code and the national digits', () {
      expect(
        PhoneEntry.e164(dial: '223', national: '70123456'),
        '+22370123456',
      );
      expect(
        PhoneEntry.e164(dial: '+223', national: '70 12 34 56'),
        '+22370123456',
      );
    });

    test('drops a trunk zero only when a whole number remains', () {
      expect(
        PhoneEntry.e164(dial: '234', national: '08031234567'),
        '+2348031234567',
      );
      expect(PhoneEntry.e164(dial: '223', national: '012345'), '+223012345');
    });

    test('keeps the zero for a country whose numbers begin with it', () {
      expect(
        PhoneEntry.e164(
          dial: '225',
          national: '0708091234',
          stripTrunkZero: false,
        ),
        '+2250708091234',
      );
    });
  });

  group('plausibility', () {
    test('needs a few digits, and not more than a number can have', () {
      expect(PhoneEntry.isPlausible(dial: '223', national: '7012'), isFalse);
      expect(PhoneEntry.isPlausible(dial: '223', national: '70123456'), isTrue);
      expect(
        PhoneEntry.isPlausible(dial: '223', national: '1234567890123'),
        isTrue,
      );
      expect(
        PhoneEntry.isPlausible(dial: '223', national: '12345678901234567'),
        isFalse,
      );
    });

    test('says which way an implausible number is wrong', () {
      expect(PhoneEntry.isTooLong(dial: '223', national: '7012'), isFalse);
      expect(
        PhoneEntry.isTooLong(dial: '223', national: '1234567890123'),
        isFalse,
        reason: 'thirteen digits and a three-digit code still fit',
      );
      expect(
        PhoneEntry.isTooLong(dial: '223', national: '12345678901234'),
        isTrue,
      );
      expect(PhoneEntry.isTooLong(dial: '1', national: '2025550123'), isFalse);
      expect(
        PhoneEntry.isTooLong(dial: '1', national: '12345678901234567'),
        isTrue,
      );
    });
  });
}
