import '../../core/money.dart';
import 'json.dart';

/// What an offer gives (the relay's control/customer_offer_terms.go).
enum OfferKind {
  /// A percentage off the order, capped by [CardOffer.maxDiscount].
  percent,

  /// A fixed amount off the order.
  amount,

  /// The more the order, the more off: [CardOffer.tiers].
  tiered,

  /// Buy [CardOffer.buyQuantity], get [CardOffer.getQuantity] more at
  /// [CardOffer.getPercent] off (100: free).
  bundle;

  static OfferKind? parse(String raw) =>
      values.where((k) => k.name == raw).firstOrNull;
}

/// One step of a tiered offer: from [minOrder], [value] off.
class OfferTier {
  const OfferTier({required this.minOrder, required this.value});

  factory OfferTier.fromJson(Map<String, dynamic> json) => OfferTier(
    minOrder: Money.parse(readString(json, 'min_order')),
    value: Money.parse(readString(json, 'value')),
  );

  final Money minOrder;

  /// A percentage (as an amount: 10.000 is 10%) or dinars, by the offer's
  /// [CardOffer.tierPercent].
  final Money value;
}

/// What an offer covers: categories, brands or single items. Empty lists
/// cover everything sold, eSIMs included (category "esim").
class OfferScope {
  const OfferScope({
    this.categories = const {},
    this.brands = const {},
    this.items = const {},
  });

  factory OfferScope.fromJson(Map<String, dynamic> json) {
    Set<String> set(String key) => {
      for (final v in (json[key] as List? ?? const [])) '$v',
    };
    return OfferScope(
      categories: set('categories'),
      brands: set('brands'),
      items: set('items'),
    );
  }

  final Set<String> categories;
  final Set<String> brands;
  final Set<String> items;

  bool get isEverything =>
      categories.isEmpty && brands.isEmpty && items.isEmpty;

  /// Whether a card of [category], [brand] and [item] is covered: it is when
  /// any of the lists names it.
  bool covers({String category = '', String brand = '', String item = ''}) =>
      isEverything ||
      (category.isNotEmpty && categories.contains(category)) ||
      (brand.isNotEmpty && brands.contains(brand)) ||
      (item.isNotEmpty && items.contains(item));
}

/// One order as an offer prices it.
class OfferLine {
  const OfferLine({
    required this.unitPrice,
    required this.quantity,
    this.category = '',
    this.brand = '',
    this.item = '',
  });

  final Money unitPrice;
  final int quantity;
  final String category;
  final String brand;
  final String item;

  Money get subtotal => unitPrice * quantity;
}

/// A discount the operator gave: to this customer (`/v1/customers/me/offers`)
/// or to everyone (`/v1/customers/offers`, shown before signing in too).
///
/// [discountOn] works the discount out the relay's way, so the app shows
/// what will be charged; the relay prices the order again and its figure is
/// the one charged.
class CardOffer {
  const CardOffer({
    required this.id,
    required this.title,
    this.description = '',
    required this.kind,
    required this.value,
    this.maxDiscount = Money.zero,
    this.minOrder = Money.zero,
    this.tiers = const [],
    this.tierPercent = true,
    this.buyQuantity = 0,
    this.getQuantity = 0,
    this.getPercent = const Money(100000),
    this.scope = const OfferScope(),
    this.badge = '',
    this.endsAt,
    this.usesLeft = 1,
    this.forEveryone = false,
  });

  /// Null for a kind this build does not know: it is left out, not guessed.
  static CardOffer? fromJson(Map<String, dynamic> json) {
    final kind = OfferKind.parse(readString(json, 'kind'));
    if (kind == null) {
      return null;
    }
    final getPercent = readString(json, 'get_percent');
    return CardOffer(
      id: readString(json, 'id'),
      title: readString(json, 'title'),
      description: readString(json, 'description'),
      kind: kind,
      value: Money.parse(readString(json, 'value')),
      maxDiscount: Money.parse(readString(json, 'max_discount')),
      minOrder: Money.parse(readString(json, 'min_order')),
      tiers: [for (final t in readList(json, 'tiers')) OfferTier.fromJson(t)],
      tierPercent: readString(json, 'tier_unit') != 'amount',
      buyQuantity: readInt(json, 'buy_quantity'),
      getQuantity: readInt(json, 'get_quantity'),
      getPercent: getPercent.isEmpty
          ? const Money(100000)
          : Money.parse(getPercent),
      scope: OfferScope.fromJson(readMap(json, 'scope')),
      badge: readString(json, 'badge'),
      endsAt: DateTime.tryParse(readString(json, 'ends_at')),
      usesLeft: readInt(json, 'uses_left'),
      forEveryone: readBool(json, 'for_everyone'),
    );
  }

  final String id;
  final String title;
  final String description;
  final OfferKind kind;

  /// The percentage (as an amount) or dinars off; a tiered offer's best
  /// tier; a bundle's [getPercent].
  final Money value;

  /// The most a percentage takes off one order; zero for no cap.
  final Money maxDiscount;
  final Money minOrder;
  final List<OfferTier> tiers;
  final bool tierPercent;
  final int buyQuantity;
  final int getQuantity;
  final Money getPercent;
  final OfferScope scope;

  /// The operator's words for the badge; empty: the app words it.
  final String badge;
  final DateTime? endsAt;
  final int usesLeft;

  /// For every customer (and shown to visitors), not chosen segments.
  final bool forEveryone;

  /// A percentage of [of], [percent] being an amount (10.000 = 10%).
  static Money _percentOf(Money of, Money percent) =>
      Money(of.dirhams * percent.dirhams ~/ 100000);

  /// The tier [subtotal] reaches, the highest; null below the first.
  OfferTier? tierFor(Money subtotal) {
    OfferTier? best;
    for (final tier in tiers) {
      if (subtotal.compareTo(tier.minOrder) >= 0) {
        best = tier;
      }
    }
    return best;
  }

  /// The tier after the one [subtotal] reaches, if there is one.
  OfferTier? nextTier(Money subtotal) {
    for (final tier in tiers) {
      if (subtotal.compareTo(tier.minOrder) < 0) {
        return tier;
      }
    }
    return null;
  }

  /// What this offer takes off [line]: nothing out of scope or below its
  /// minimum, never more than the order, down to the dirham.
  Money discountOn(OfferLine line) {
    final subtotal = line.subtotal;
    if (!subtotal.isPositive ||
        !scope.covers(
          category: line.category,
          brand: line.brand,
          item: line.item,
        ) ||
        subtotal.compareTo(minOrder) < 0) {
      return Money.zero;
    }
    var capped = true;
    Money off;
    switch (kind) {
      case OfferKind.percent:
        off = _percentOf(subtotal, value);
      case OfferKind.amount:
        off = value;
        capped = false;
      case OfferKind.tiered:
        final tier = tierFor(subtotal);
        if (tier == null) {
          return Money.zero;
        }
        off = tierPercent ? _percentOf(subtotal, tier.value) : tier.value;
        capped = tierPercent;
      case OfferKind.bundle:
        final group = buyQuantity + getQuantity;
        if (buyQuantity <= 0 || getQuantity <= 0) {
          return Money.zero;
        }
        final discounted = line.quantity ~/ group * getQuantity;
        off = _percentOf(line.unitPrice * discounted, getPercent);
    }
    if (capped && maxDiscount.isPositive && off.compareTo(maxDiscount) > 0) {
      off = maxDiscount;
    }
    return off.compareTo(subtotal) > 0 ? subtotal : off;
  }

  /// The best of [offers] for [line], or null when none takes anything off.
  static CardOffer? bestFor(Iterable<CardOffer> offers, OfferLine line) {
    CardOffer? best;
    var most = Money.zero;
    for (final offer in offers) {
      final off = offer.discountOn(line);
      if (off.compareTo(most) > 0) {
        best = offer;
        most = off;
      }
    }
    return best;
  }
}
