import '../../../data/models/service_kinds.dart';
import '../../../data/models/voucher_menu.dart';
import 'voucher_search_synonyms.dart';

/// Arabic and Latin text as the menu search compares it: lower case, no
/// tashkeel or tatweel, alef and ya and ta marbuta folded, Arabic-Indic digits
/// made plain, runs of spaces made one.
String normalizeVoucherSearchText(String text) {
  final out = StringBuffer();
  var lastSpace = true;
  for (final rune in text.runes) {
    // Tashkeel, dagger alef and tatweel.
    if ((rune >= 0x064B && rune <= 0x065F) ||
        rune == 0x0670 ||
        rune == 0x0640) {
      continue;
    }
    var char = String.fromCharCode(rune);
    char = switch (char) {
      'أ' || 'إ' || 'آ' || 'ٱ' => 'ا',
      'ة' => 'ه',
      'ى' => 'ي',
      _ => char.toLowerCase(),
    };
    if (rune >= 0x0660 && rune <= 0x0669) {
      char = String.fromCharCode(0x30 + rune - 0x0660);
    }
    final isSpace = char.trim().isEmpty || char == '-' || char == '_';
    if (isSpace) {
      if (!lastSpace) {
        out.write(' ');
      }
      lastSpace = true;
    } else {
      out.write(char);
      lastSpace = false;
    }
  }
  return out.toString().trim();
}

/// What a typed query finds on the «كروت دفتر» menu.
class VoucherMenuSearchResult {
  const VoucherMenuSearchResult({
    this.brands = const [],
    this.airtime = false,
    this.bills = const [],
  });

  /// In the menu's own order.
  final List<VoucherBrand> brands;

  /// The direct top-up launcher is a hit.
  final bool airtime;

  /// The bill types whose card is a hit, in the menu's order.
  final List<BillType> bills;

  bool get isEmpty => brands.isEmpty && !airtime && bills.isEmpty;
}

/// Filters [menu] by [query]: a brand by its Arabic name, aliases, key (which
/// is its English name) — every typed word has to appear in them — and
/// whatever the synonym table adds. A blank query finds nothing in particular;
/// the caller shows the whole menu then.
VoucherMenuSearchResult searchVoucherMenu(
  VoucherMenu menu,
  String query, {
  List<VoucherSynonym> synonyms = voucherSearchSynonyms,
}) {
  final normalized = normalizeVoucherSearchText(query);
  if (normalized.isEmpty) {
    return VoucherMenuSearchResult(brands: menu.brands);
  }
  final words = normalized.split(' ');

  final extraTerms = <String>[];
  var airtime = false;
  final billTypes = <BillType>{};
  for (final synonym in synonyms) {
    if (!_triggered(synonym, normalized, words)) {
      continue;
    }
    extraTerms.addAll(synonym.brandTerms.map(normalizeVoucherSearchText));
    airtime = airtime || synonym.airtime;
    billTypes.addAll(synonym.bills);
  }

  final brands = [
    for (final brand in menu.brands)
      if (_brandMatches(brand, words, extraTerms)) brand,
  ];
  return VoucherMenuSearchResult(
    brands: brands,
    airtime: airtime && menu.airtimeService != null,
    bills: [
      for (final service in menu.billServices)
        if (billTypes.contains(service.billType)) service.billType,
    ],
  );
}

bool _triggered(VoucherSynonym synonym, String normalized, List<String> words) {
  for (final raw in synonym.triggers) {
    final trigger = normalizeVoucherSearchText(raw);
    if (trigger.isEmpty) {
      continue;
    }
    if (trigger.contains(' ')) {
      if (normalized.contains(trigger) ||
          (normalized.length >= 3 && trigger.startsWith(normalized))) {
        return true;
      }
    } else if (words.any(
      (word) =>
          word == trigger || (word.length >= 3 && trigger.startsWith(word)),
    )) {
      return true;
    }
  }
  return false;
}

bool _brandMatches(
  VoucherBrand brand,
  List<String> words,
  List<String> extraTerms,
) {
  final haystack = normalizeVoucherSearchText(
    [brand.name, ...brand.aliases, brand.key].join(' '),
  );
  if (words.every(haystack.contains)) {
    return true;
  }
  return extraTerms.any((term) => term.isNotEmpty && haystack.contains(term));
}
