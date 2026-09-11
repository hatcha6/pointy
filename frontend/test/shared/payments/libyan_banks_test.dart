import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/payments/libyan_banks.dart';

void main() {
  group('the register', () {
    test('carries every bank the Central Bank lists', () {
      expect(libyanBanks, hasLength(25));
    });

    test('every entry is complete and uniquely identified', () {
      final slugs = <String>{};
      for (final bank in libyanBanks) {
        expect(bank.slug, isNotEmpty, reason: 'slug missing');
        expect(bank.arabicName, isNotEmpty, reason: '${bank.slug} has no Arabic name');
        expect(bank.englishName, isNotEmpty, reason: '${bank.slug} has no English name');
        expect(
          bank.logoAsset,
          'assets/banks/${bank.slug}.png',
          reason: '${bank.slug} logo must be keyed on the slug, not a source filename',
        );
        expect(slugs.add(bank.slug), isTrue, reason: 'duplicate slug ${bank.slug}');
      }
    });

    test('every declared logo is really on disk', () {
      // The marks are optional at RUNTIME — BankLogo falls back to the name —
      // but an entry naming a file nobody added is a typo, not a choice, and
      // it would degrade silently forever. Any bank deliberately shipping
      // without a mark belongs in the exemption list below, named.
      const knownMissing = <String>{};
      final absent = <String>[];
      for (final bank in libyanBanks) {
        if (knownMissing.contains(bank.slug)) {
          continue;
        }
        if (!File(bank.logoAsset).existsSync()) {
          absent.add('${bank.slug} -> ${bank.logoAsset}');
        }
      }
      expect(absent, isEmpty, reason: 'declared but missing:\n${absent.join('\n')}');
    });

    test('no stray marks sit in the folder unclaimed', () {
      // A file named for a bank that is not in the register means somebody
      // saved it under the source's filename instead of the slug — the exact
      // mistake that puts one bank's mark on another bank's card.
      final declared = {for (final bank in libyanBanks) bank.logoAsset};
      final stray = Directory('assets/banks')
          .listSync()
          .whereType<File>()
          .map((file) => file.path)
          .where((path) => path.endsWith('.png'))
          .where((path) => !declared.contains(path))
          .toList();
      expect(stray, isEmpty, reason: 'unclaimed files:\n${stray.join('\n')}');
    });

    test('the two banks whose source filenames lie stay apart', () {
      // nub-logo.png is National Union Bank, but the slug `nub` is Nuran Bank.
      // Deriving either from the other swaps two real, different banks.
      expect(bankForSlug('ejmaa')!.englishName, 'National Union Bank');
      expect(bankForSlug('nub')!.englishName, 'Nuran Bank');
      expect(bankForSlug('ejmaa')!.logoAsset, isNot(bankForSlug('nub')!.logoAsset));
      // sb is Sahara Bank, whose source logo is still named for BNP Paribas.
      expect(bankForSlug('sb')!.englishName, 'Sahara Bank');
    });
  });

  group('reading a BIN off a masked PAN', () {
    test('Moamalat prints one', () {
      expect(binFromMaskedPan('639974*********8809'), '639974');
    });

    test('Madfoatech does not, and its last four are not a BIN', () {
      // The trailing 5091 are the LAST four digits. Reading them as a BIN would
      // look up a bank that has nothing to do with this card.
      expect(binFromMaskedPan('************5091'), isNull);
    });

    test('a PAN that failed OCR yields nothing', () {
      expect(binFromMaskedPan('KREKEERAERERSOGT'), isNull);
      expect(binFromMaskedPan(''), isNull);
      expect(binFromMaskedPan(null), isNull);
    });

    test('too few leading digits is not a BIN', () {
      expect(binFromMaskedPan('6399**********8809'), isNull);
    });
  });

  group('resolving the issuing bank', () {
    test('a BIN read off a real card resolves to that bank', () {
      // Both confirmed from the cards themselves, not from a BIN database and
      // not from memory — the recalled mapping for 639974 was wrong.
      final andalus = bankForMaskedPan('639974*********8809');
      expect(andalus?.slug, 'andalus');
      expect(andalus?.arabicName, 'مصرف الأندلس');

      final northAfrica = bankForMaskedPan('639500*********1234');
      expect(northAfrica?.slug, 'nab');
      expect(northAfrica?.arabicName, 'مصرف شمال أفريقيا');
    });

    test('an unknown BIN resolves to nothing rather than guessing', () {
      // Neighbouring BINs must not borrow a listed bank's identity.
      expect(bankForMaskedPan('639975*********8809'), isNull);
      expect(bankForMaskedPan('123456*********8809'), isNull);
    });

    test('a Madfoatech PAN can never resolve, whatever the table holds', () {
      expect(bankForMaskedPan('************5091'), isNull);
    });

    test('every seeded BIN points at a bank that exists', () {
      // Guards the table against a typo'd slug, which would otherwise resolve
      // to null at runtime and silently look like "unknown bank".
      for (final entry in bankBinRanges.entries) {
        expect(
          bankForSlug(entry.value),
          isNotNull,
          reason: 'BIN ${entry.key} maps to unknown slug "${entry.value}"',
        );
        expect(
          entry.key,
          matches(RegExp(r'^\d{6}$')),
          reason: 'BIN ${entry.key} must be exactly six digits',
        );
      }
    });
  });
}
