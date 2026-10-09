import '../../../data/models/service_kinds.dart';

/// What a typed word means beyond the letters it is made of, for the «كروت
/// دفتر» menu: «visa» finds the prepaid Mastercard, «electricity» the
/// electricity bill card. A small hand-kept table, so a cashier's habit
/// ("apple" for آيتونز) works even when the server sent no aliases.
///
/// Triggers and terms are written naturally; the search normalizes both.
class VoucherSynonym {
  const VoucherSynonym({
    required this.triggers,
    this.brandTerms = const [],
    this.airtime = false,
    this.bills = const [],
  });

  /// Words a cashier types. A single word matches a typed word that is it, or
  /// that it starts with (from three letters); a phrase matches when the query
  /// contains it or it starts with the query.
  final List<String> triggers;

  /// Brand names, aliases or keys the trigger also finds.
  final List<String> brandTerms;

  /// The trigger also finds the direct top-up launcher.
  final bool airtime;

  /// The trigger also finds these bill-type cards.
  final List<BillType> bills;
}

const voucherSearchSynonyms = <VoucherSynonym>[
  VoucherSynonym(
    triggers: ['visa', 'فيزا', 'prepaid', 'بطاقة دفع', 'master card'],
    brandTerms: ['mastercard', 'ماستركارد'],
  ),
  VoucherSynonym(
    triggers: ['apple', 'app store', 'appstore', 'أبل', 'ابل', 'آبل', 'itunes'],
    brandTerms: ['itunes', 'آيتونز', 'apple'],
  ),
  VoucherSynonym(
    triggers: ['playstation', 'psn', 'ps4', 'ps5', 'بلايستيشن', 'بلاي ستيشن'],
    brandTerms: ['playstation', 'بلايستيشن'],
  ),
  VoucherSynonym(
    triggers: ['xbox', 'اكس بوكس', 'إكس بوكس'],
    brandTerms: ['xbox'],
  ),
  VoucherSynonym(
    triggers: [
      'top up',
      'topup',
      'recharge',
      'airtime',
      'credit',
      'شحن رصيد',
      'شحن',
      'رصيد',
    ],
    airtime: true,
  ),
  VoucherSynonym(
    triggers: ['electricity', 'electric', 'كهرباء', 'كهربا', 'الكهرباء'],
    bills: [BillType.electricity],
  ),
  VoucherSynonym(
    triggers: ['water', 'مياه', 'ماء', 'المياه'],
    bills: [BillType.water],
  ),
  VoucherSynonym(
    triggers: ['tv', 'television', 'تلفزيون', 'تلفاز', 'قنوات'],
    bills: [BillType.tv],
  ),
  VoucherSynonym(
    triggers: ['internet', 'wifi', 'انترنت', 'إنترنت', 'الانترنت'],
    bills: [BillType.internet],
  ),
];
