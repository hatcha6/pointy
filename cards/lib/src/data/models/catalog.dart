import '../../core/money.dart';
import 'json.dart';

/// The card shelf as the relay shows this app build (`GET
/// /v1/customers/catalog`): retail prices only, narrowed to what the channel
/// may sell.
class CardCatalog {
  const CardCatalog({
    required this.version,
    required this.channel,
    required this.testMode,
    required this.categories,
    required this.countries,
    required this.brands,
  });

  factory CardCatalog.fromJson(Map<String, dynamic> json) => CardCatalog(
    version: readString(json, 'version'),
    channel: readString(json, 'channel'),
    testMode: readBool(json, 'test_mode'),
    categories: [
      for (final c in readList(json, 'categories')) CardCategory.fromJson(c),
    ],
    countries: [
      for (final c in readList(json, 'countries')) CardCountry.fromJson(c),
    ],
    brands: [for (final b in readList(json, 'brands')) CardBrand.fromJson(b)],
  );

  static const empty = CardCatalog(
    version: '',
    channel: '',
    testMode: false,
    categories: [],
    countries: [],
    brands: [],
  );

  final String version;
  final String channel;
  final bool testMode;
  final List<CardCategory> categories;
  final List<CardCountry> countries;
  final List<CardBrand> brands;

  CardBrand? brand(String key) {
    for (final brand in brands) {
      if (brand.key == key) {
        return brand;
      }
    }
    return null;
  }
}

class CardCategory {
  const CardCategory({
    required this.key,
    required this.name,
    required this.rank,
  });

  factory CardCategory.fromJson(Map<String, dynamic> json) => CardCategory(
    key: readString(json, 'key'),
    name: readString(json, 'name'),
    rank: readInt(json, 'rank'),
  );

  final String key;
  final String name;
  final int rank;
}

class CardCountry {
  const CardCountry({
    required this.code,
    required this.name,
    required this.flag,
  });

  factory CardCountry.fromJson(Map<String, dynamic> json) => CardCountry(
    code: readString(json, 'code'),
    name: readString(json, 'name'),
    flag: readString(json, 'flag'),
  );

  final String code;
  final String name;

  /// An image reference ("sha256:…") served by `/v1/customers/images/`.
  final String flag;
}

class CardBrand {
  const CardBrand({
    required this.key,
    required this.name,
    required this.aliases,
    required this.category,
    required this.rank,
    required this.featured,
    required this.badge,
    required this.redeemHint,
    required this.logo,
    required this.items,
  });

  factory CardBrand.fromJson(Map<String, dynamic> json) => CardBrand(
    key: readString(json, 'key'),
    name: readString(json, 'name'),
    aliases: [
      for (final alias in (json['aliases'] as List? ?? const []))
        if (alias is String) alias,
    ],
    category: readString(json, 'category'),
    rank: readInt(json, 'rank'),
    featured: readBool(json, 'featured'),
    badge: readString(json, 'badge'),
    redeemHint: readString(json, 'redeem_hint'),
    logo: readString(json, 'logo'),
    items: [for (final i in readList(json, 'items')) CardItem.fromJson(i)],
  );

  final String key;
  final String name;
  final List<String> aliases;
  final String category;
  final int rank;
  final bool featured;
  final String badge;
  final String redeemHint;

  /// The card art reference, or empty when the brand has none.
  final String logo;
  final List<CardItem> items;

  bool get anyAvailable => items.any((item) => item.available);

  /// The cheapest price among the sellable cards (all, when none is).
  Money? get fromPrice {
    final available = items.where((item) => item.available).toList();
    return (available.isEmpty ? items : available)
        .map((item) => item.price)
        .fold<Money?>(
          null,
          (min, price) => min == null || price.compareTo(min) < 0 ? price : min,
        );
  }
}

class CardItem {
  const CardItem({
    required this.key,
    required this.country,
    required this.label,
    required this.faceValue,
    required this.faceCurrency,
    required this.price,
    required this.regularPrice,
    required this.promoBadge,
    required this.available,
    required this.rank,
  });

  factory CardItem.fromJson(Map<String, dynamic> json) {
    final promo = readMap(json, 'promo');
    return CardItem(
      key: readString(json, 'key'),
      country: readString(json, 'country'),
      label: readString(json, 'label'),
      faceValue: readString(json, 'face_value'),
      faceCurrency: readString(json, 'face_currency'),
      price: Money.parse(readString(json, 'price')),
      regularPrice: Money.parse(readString(json, 'regular_price')),
      promoBadge: readString(promo, 'badge'),
      available: readBool(json, 'available'),
      rank: readInt(json, 'rank'),
    );
  }

  final String key;
  final String country;
  final String label;
  final String faceValue;
  final String faceCurrency;

  /// What the customer pays for one.
  final Money price;
  final Money regularPrice;
  final String promoBadge;
  final bool available;
  final int rank;

  bool get onPromo => regularPrice > price;
}

extension on Money {
  bool operator >(Money other) => compareTo(other) > 0;
}
