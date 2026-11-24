import '../../core/money.dart';
import 'json.dart';

/// A discount the operator gave this customer (`GET /v1/customers/me/offers`):
/// a percentage, capped, or an amount off an order of at least [minOrder].
///
/// [discountOn] works the discount out the relay's way, so the checkout shows
/// what will be charged; the relay prices the order again and its figure is
/// the one charged.
class CardOffer {
  const CardOffer({
    required this.id,
    required this.title,
    required this.description,
    required this.percent,
    required this.value,
    required this.maxDiscount,
    required this.minOrder,
    required this.endsAt,
    required this.usesLeft,
  });

  factory CardOffer.fromJson(Map<String, dynamic> json) => CardOffer(
    id: readString(json, 'id'),
    title: readString(json, 'title'),
    description: readString(json, 'description'),
    percent: readString(json, 'kind') == 'percent',
    value: Money.parse(readString(json, 'value')),
    maxDiscount: Money.parse(readString(json, 'max_discount')),
    minOrder: Money.parse(readString(json, 'min_order')),
    endsAt: DateTime.tryParse(readString(json, 'ends_at')),
    usesLeft: readInt(json, 'uses_left'),
  );

  final String id;
  final String title;
  final String description;

  /// A percentage off (its [value] is the percent, as an amount), else an
  /// amount off.
  final bool percent;
  final Money value;

  /// The most a percentage takes off one order; zero for no cap.
  final Money maxDiscount;
  final Money minOrder;
  final DateTime? endsAt;
  final int usesLeft;

  /// What this offer takes off an order of [subtotal]: nothing below its
  /// minimum, never more than the order, down to the dirham.
  Money discountOn(Money subtotal) {
    if (!subtotal.isPositive ||
        !value.isPositive ||
        subtotal.compareTo(minOrder) < 0) {
      return Money.zero;
    }
    var off = percent
        // value.dirhams is the percent × 1000.
        ? Money(subtotal.dirhams * value.dirhams ~/ 100000)
        : value;
    if (percent && maxDiscount.isPositive && off.compareTo(maxDiscount) > 0) {
      off = maxDiscount;
    }
    return off.compareTo(subtotal) > 0 ? subtotal : off;
  }

  /// The best of [offers] for an order of [subtotal], or null when none
  /// takes anything off it.
  static CardOffer? bestFor(Iterable<CardOffer> offers, Money subtotal) {
    CardOffer? best;
    var most = Money.zero;
    for (final offer in offers) {
      final off = offer.discountOn(subtotal);
      if (off.compareTo(most) > 0) {
        best = offer;
        most = off;
      }
    }
    return best;
  }
}
