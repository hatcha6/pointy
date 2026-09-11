/// The Libyan banks a card receipt might belong to, and how to find one.
///
/// The list is the Central Bank of Libya's own, taken from its foreign-currency
/// platform, which is the closest thing to an authoritative register. Each entry
/// is written out in full rather than derived from anything, because the
/// source's own naming cannot be trusted to identify a bank:
///
/// * `nub-logo.png` is **National Union Bank** (`ejmaa`), while the slug `nub`
///   is **Nuran Bank**. Keying on a filename, or on the obvious abbreviation,
///   silently swaps two different banks.
/// * `sb` is **Sahara Bank**, but its logo is still `bnp-bank.png` from the
///   years BNP Paribas held a stake.
///
/// So slug, Arabic name, English name and asset path are each stated. Nothing
/// here is inferred from anything else here.
library;

/// One bank, as the shop would recognise it.
class LibyanBank {
  const LibyanBank({
    required this.slug,
    required this.arabicName,
    required this.englishName,
    required this.logoAsset,
  });

  /// The Central Bank's own identifier for this bank.
  final String slug;

  /// What a Libyan shopkeeper calls it. The app is Arabic-first, so this is the
  /// name shown; the English one is for reconciliation against bank statements.
  final String arabicName;
  final String englishName;

  /// Where the bank's mark lives in the bundle.
  ///
  /// The file may legitimately be absent — the marks are bank trademarks and
  /// are added deliberately — so every surface that draws one must fall back to
  /// [arabicName]. A missing logo is a cosmetic gap, never a blank row.
  final String logoAsset;
}

/// Every bank in the Central Bank's register, in its order.
const libyanBanks = <LibyanBank>[
  LibyanBank(
    slug: 'lib',
    arabicName: 'المصرف الإسلامي الليبي',
    englishName: 'Libyan Islamic Bank',
    logoAsset: 'assets/banks/lib.png',
  ),
  LibyanBank(
    slug: 'tad',
    arabicName: 'المصرف التضامن',
    englishName: 'Tadhamun Bank',
    logoAsset: 'assets/banks/tad.png',
  ),
  LibyanBank(
    slug: 'lfb',
    arabicName: 'المصرف الليبي الخارجي',
    englishName: 'Libyan Foreign Bank',
    logoAsset: 'assets/banks/lfb.png',
  ),
  LibyanBank(
    slug: 'aman',
    arabicName: 'مصرف الأمان',
    englishName: 'Aman Bank',
    logoAsset: 'assets/banks/aman.png',
  ),
  LibyanBank(
    slug: 'andalus',
    arabicName: 'مصرف الأندلس',
    englishName: 'Andalus Bank',
    logoAsset: 'assets/banks/andalus.png',
  ),
  LibyanBank(
    slug: 'aiib',
    arabicName: 'مصرف الإستثمار العربي الإسلامي',
    englishName: 'Arab Islamic Investment Bank',
    logoAsset: 'assets/banks/aiib.png',
  ),
  LibyanBank(
    slug: 'ejmaa',
    arabicName: 'مصرف الاتحاد الوطني',
    englishName: 'National Union Bank',
    logoAsset: 'assets/banks/ejmaa.png',
  ),
  LibyanBank(
    slug: 'bcdb',
    arabicName: 'مصرف التجارة والتنمية',
    englishName: 'Bank of Commerce & Development',
    logoAsset: 'assets/banks/bcdb.png',
  ),
  LibyanBank(
    slug: 'ncb',
    arabicName: 'مصرف التجاري الوطني',
    englishName: 'National Commercial Bank',
    logoAsset: 'assets/banks/ncb.png',
  ),
  LibyanBank(
    slug: 'ifb',
    arabicName: 'مصرف التمويل الاسلامي',
    englishName: 'Islamic Finance Bank',
    logoAsset: 'assets/banks/ifb.png',
  ),
  LibyanBank(
    slug: 'devb',
    arabicName: 'مصرف التنمية',
    englishName: 'Development Bank',
    logoAsset: 'assets/banks/devb.png',
  ),
  LibyanBank(
    slug: 'jbank',
    arabicName: 'مصرف الجمهورية',
    englishName: 'Jumhouria Bank',
    logoAsset: 'assets/banks/jbank.png',
  ),
  LibyanBank(
    slug: 'fglb',
    arabicName: 'مصرف الخليج الأول',
    englishName: 'First Gulf Libyan Bank',
    logoAsset: 'assets/banks/fglb.png',
  ),
  LibyanBank(
    slug: 'sib',
    arabicName: 'مصرف السراج الاسلامي',
    englishName: 'Alseraj Islamic Bank',
    logoAsset: 'assets/banks/sib.png',
  ),
  LibyanBank(
    slug: 'atib',
    arabicName: 'مصرف السراي',
    englishName: 'Assaray Bank',
    logoAsset: 'assets/banks/atib.png',
  ),
  LibyanBank(
    slug: 'sb',
    arabicName: 'مصرف الصحارى',
    englishName: 'Sahara Bank',
    logoAsset: 'assets/banks/sb.png',
  ),
  LibyanBank(
    slug: 'dib',
    arabicName: 'مصرف الضمان الاسلامي',
    englishName: 'Daman Islamic Bank',
    logoAsset: 'assets/banks/dib.png',
  ),
  LibyanBank(
    slug: 'ubci',
    arabicName: 'مصرف المتحد',
    englishName: 'UBCI Bank',
    logoAsset: 'assets/banks/ubci.png',
  ),
  LibyanBank(
    slug: 'med',
    arabicName: 'مصرف المتوسط',
    englishName: 'Meditbank',
    logoAsset: 'assets/banks/med.png',
  ),
  LibyanBank(
    slug: 'nub',
    arabicName: 'مصرف النوران',
    englishName: 'Nuran Bank',
    logoAsset: 'assets/banks/nub.png',
  ),
  LibyanBank(
    slug: 'wab',
    arabicName: 'مصرف الواحة',
    englishName: 'Waha Bank',
    logoAsset: 'assets/banks/wab.png',
  ),
  LibyanBank(
    slug: 'wb',
    arabicName: 'مصرف الوحدة',
    englishName: 'Wehda Bank',
    logoAsset: 'assets/banks/wb.png',
  ),
  LibyanBank(
    slug: 'alwafa',
    arabicName: 'مصرف الوفاء',
    englishName: 'Alwafa Bank',
    logoAsset: 'assets/banks/alwafa.png',
  ),
  LibyanBank(
    slug: 'yaqeen',
    arabicName: 'مصرف اليقين',
    englishName: 'Yaqeen Bank',
    logoAsset: 'assets/banks/yaqeen.png',
  ),
  LibyanBank(
    slug: 'nab',
    arabicName: 'مصرف شمال أفريقيا',
    englishName: 'North Africa Bank',
    logoAsset: 'assets/banks/nab.png',
  ),
];

/// Which bank issued a card, keyed on the leading digits of its PAN.
///
/// The BIN (the first six digits) is the only thing on a receipt that names the
/// issuing bank, and it only works when the terminal prints it. Moamalat does
/// (`639974*********8809`); Madfoatech masks everything but the last four
/// (`************5091`), so a card taken on that acquirer can never be resolved
/// here no matter how complete this table becomes.
///
/// Entries come only from a card held in hand, never from a recollection and
/// never from an online BIN database. Both were tried: the aggregators do not
/// carry these at all — Libyan domestic cards run on the national switches
/// (Moamalat's NUMO, Tadawul) and international BIN registries index only
/// Visa/Mastercard issuance — and one of them served a US bank on its Libya
/// page. A recalled mapping was wrong on the first BIN we checked. A plausible
/// wrong bank shown with a logo beside it is worse than no bank at all, so an
/// unverified range stays out.
///
/// Six digits is the most this can ever resolve, and that is a property of the
/// data rather than a choice: Moamalat masks a PAN as `639974*********8809`, so
/// only the leading six are ever legible. If the national scheme turns out to
/// sub-allocate inside a six-digit prefix, the affected entry must be REMOVED
/// rather than guessed at — a receipt simply cannot tell those cards apart.
const bankBinRanges = <String, String>{
  // Read off the cards themselves.
  '639974': 'andalus',
  '639500': 'nab',
};

/// The bank that issued a card, or `null` when the receipt cannot say.
///
/// `null` is the ordinary answer and every caller must render it as *absence* —
/// no logo, no name, no placeholder. There is no fallback to a "most likely"
/// bank, because a plausible wrong bank on a receipt is exactly the error this
/// whole path exists to avoid.
LibyanBank? bankForMaskedPan(String? maskedPan) {
  final bin = binFromMaskedPan(maskedPan);
  if (bin == null) {
    return null;
  }
  final slug = bankBinRanges[bin];
  if (slug == null) {
    return null;
  }
  return bankForSlug(slug);
}

/// The six-digit BIN a masked PAN reveals, or `null` when it reveals none.
///
/// Only *leading* digits count. A PAN masked as `************5091` ends in real
/// digits, but they are the last four — reading them as a BIN would look up an
/// entirely unrelated bank.
String? binFromMaskedPan(String? maskedPan) {
  final text = (maskedPan ?? '').trim();
  final match = RegExp(r'^(\d{6,})').firstMatch(text);
  if (match == null) {
    return null;
  }
  return match.group(1)!.substring(0, 6);
}

LibyanBank? bankForSlug(String slug) {
  for (final bank in libyanBanks) {
    if (bank.slug == slug) {
      return bank;
    }
  }
  return null;
}
