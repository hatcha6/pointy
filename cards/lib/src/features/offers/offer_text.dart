import '../../core/money.dart';
import '../../data/models/offer.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../shared/money_text.dart';

/// A percentage kept as an amount (15.000) as it is read: 15, or 12.5.
String percentText(Money percent) {
  final whole = percent.dirhams ~/ 1000;
  final rest = percent.dirhams % 1000;
  if (rest == 0) {
    return '$whole';
  }
  return (percent.dirhams / 1000)
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// What a tier or a percent offer gives, in words: "15٪" or "5.00 د.ل".
String offerValueText(
  AppLocalizations l10n,
  Money value, {
  required bool percent,
}) => percent ? '${percentText(value)}٪' : formatMoney(l10n, value);

/// The badge an offer wears on a card: the operator's words, else its terms.
String offerBadgeText(AppLocalizations l10n, CardOffer offer) {
  if (offer.badge.isNotEmpty) {
    return offer.badge;
  }
  return switch (offer.kind) {
    OfferKind.percent => l10n.offerBadgePercent(percentText(offer.value)),
    OfferKind.amount => l10n.offerBadgeAmount(formatMoney(l10n, offer.value)),
    OfferKind.tiered => l10n.offerBadgeUpTo(
      offerValueText(
        l10n,
        offer.tiers.isEmpty ? offer.value : offer.tiers.last.value,
        percent: offer.tierPercent,
      ),
    ),
    OfferKind.bundle =>
      offer.getPercent.compareTo(const Money(100000)) >= 0
          ? l10n.offerBadgeBundleFree(
              '${offer.buyQuantity}',
              '${offer.getQuantity}',
            )
          : l10n.offerBadgeBundlePercent(
              '${offer.buyQuantity}',
              percentText(offer.getPercent),
            ),
  };
}

/// A nudge to a better deal for [line]: one more card for a bundle, a little
/// more for the next tier, the offer's minimum. Null when there is none.
({String text, String kind})? offerNudge(
  AppLocalizations l10n,
  CardOffer offer,
  OfferLine line,
) {
  if (!offer.scope.covers(
    category: line.category,
    brand: line.brand,
    item: line.item,
  )) {
    return null;
  }
  final subtotal = line.subtotal;
  switch (offer.kind) {
    case OfferKind.bundle:
      final group = offer.buyQuantity + offer.getQuantity;
      if (group <= 0) {
        return null;
      }
      final short = group - line.quantity % group;
      // Only the next whole group: halfway into a second one is no nudge.
      if (line.quantity >= group && line.quantity % group == 0) {
        return null;
      }
      return (text: l10n.offerNudgeBundle('$short'), kind: 'bundle');
    case OfferKind.tiered:
      final next = offer.nextTier(subtotal);
      if (next == null) {
        return null;
      }
      return (
        text: l10n.offerNudgeTier(
          formatMoney(l10n, next.minOrder - subtotal),
          offerValueText(l10n, next.value, percent: offer.tierPercent),
        ),
        kind: 'tier',
      );
    case OfferKind.percent || OfferKind.amount:
      if (subtotal.compareTo(offer.minOrder) >= 0) {
        return null;
      }
      return (
        text: l10n.offerMinOrder(formatMoney(l10n, offer.minOrder)),
        kind: 'minimum',
      );
  }
}

/// When an offer ends, in words; null for one with no end, or a week away.
String? offerEndsText(AppLocalizations l10n, CardOffer offer, DateTime now) {
  final ends = offer.endsAt;
  if (ends == null) {
    return null;
  }
  final left = ends.difference(now);
  if (left.isNegative || left.inDays > 7) {
    return null;
  }
  return left.inHours < 24
      ? l10n.offerEndsToday
      : l10n.offerEndsIn(left.inDays + 1);
}

/// An offer's value in large type, with the word under it: "15٪ / خصم",
/// "15٪ / خصم حتى", "2+1 / مجاناً".
({String value, String caption}) offerHeadline(
  AppLocalizations l10n,
  CardOffer offer,
) => switch (offer.kind) {
  OfferKind.percent => (
    value: '${percentText(offer.value)}٪',
    caption: l10n.offerHeroOff,
  ),
  OfferKind.amount => (
    value: formatMoney(l10n, offer.value),
    caption: l10n.offerHeroOff,
  ),
  OfferKind.tiered => (
    value: offerValueText(
      l10n,
      offer.tiers.isEmpty ? offer.value : offer.tiers.last.value,
      percent: offer.tierPercent,
    ),
    caption: l10n.offerHeroUpTo,
  ),
  OfferKind.bundle =>
    offer.getPercent.compareTo(const Money(100000)) >= 0
        ? (
            value: '${offer.buyQuantity}+${offer.getQuantity}',
            caption: l10n.offerHeroFree,
          )
        : (
            value: '${percentText(offer.getPercent)}٪',
            caption: l10n.offerHeroNext,
          ),
};

/// When the first of [offers] to end ends, in words, if that is soon.
String? offersSoonestEnd(
  AppLocalizations l10n,
  List<CardOffer> offers,
  DateTime now,
) {
  final ending = [
    for (final offer in offers)
      if (offer.endsAt != null) offer,
  ]..sort((a, b) => a.endsAt!.compareTo(b.endsAt!));
  return ending.isEmpty ? null : offerEndsText(l10n, ending.first, now);
}
