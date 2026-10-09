/// The till's «كروت دفتر» menu: the company's own prepaid cards, in the
/// categories and the order the company chose, each brand carrying the system
/// product its cart lines point at.
///
/// `GET /api/integrations/vouchers/menu/`. Parsed tolerantly: a field a server
/// leaves out or sends malformed becomes its empty value instead of failing the
/// whole menu — one bad brand must never cost the till the others.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'product.dart';
import 'product_variant.dart';
import 'service_kinds.dart';

class VoucherMenu {
  const VoucherMenu({
    required this.available,
    this.provider = '',
    this.errorCode = '',
    this.balance,
    this.balanceAt,
    this.categories = const [],
    this.countries = const [],
    this.brands = const [],
    this.services = const [],
    this.testMode = false,
    this.canEditPricing = false,
  });

  /// What a server with nothing to say amounts to.
  static const empty = VoucherMenu(available: false);

  factory VoucherMenu.fromJson(Map<String, Object?> json) {
    return VoucherMenu(
      available: json['available'] == true,
      provider: _string(json['provider']),
      errorCode: _string(json['error_code']),
      balance: _amountOrNull(json['balance']),
      balanceAt: _date(json['balance_at']),
      categories: _list(
        json['categories'],
        VoucherMenuCategory.fromJson,
      ).where((category) => category.key.isNotEmpty).toList(growable: false),
      countries: _list(
        json['countries'],
        VoucherCountry.fromJson,
      ).where((country) => country.code.isNotEmpty).toList(growable: false),
      // A brand with no cards has nothing to show.
      brands: _list(
        json['brands'],
        VoucherBrand.fromJson,
      ).where((brand) => brand.items.isNotEmpty).toList(growable: false),
      services: _list(
        json['services'],
        VoucherMenuService.fromJson,
      ).where((service) => service.key.isNotEmpty).toList(growable: false),
      // Absent is not "test": only an explicit true puts the till in it.
      testMode: json['test_mode'] == true,
      canEditPricing: json['can_edit_pricing'] == true,
    );
  }

  /// The shop sells these cards right now. False when the provider is not
  /// switched on, or was switched off for every shop ([errorCode] says which).
  final bool available;
  final String provider;

  /// Why [available] is false, as the server coded it.
  final String errorCode;

  /// The voucher balance the cards are paid from, as last read.
  final double? balance;
  final DateTime? balanceAt;

  /// The company's categories, in display order.
  final List<VoucherMenuCategory> categories;

  /// Every country a card is for, with its Arabic name and flag.
  final List<VoucherCountry> countries;

  /// In display order.
  final List<VoucherBrand> brands;

  /// The direct services the company sells besides its cards — airtime sent
  /// to a phone abroad, bills paid abroad — one entry per card the till draws.
  final List<VoucherMenuService> services;

  /// The relay is buying from its test supplier: nothing sent is real and
  /// nothing paid is paid. Said for the whole menu here, and again on each
  /// service ([VoucherMenuService.testMode]).
  final bool testMode;

  /// The viewer may set the shop's prices for these cards (owner/manager).
  final bool canEditPricing;

  /// Anything on this menu is in test mode — the menu as a whole, or any of
  /// its services.
  bool get isTestMode =>
      testMode || services.any((service) => service.testMode);

  /// Whether there is anything to put on the menu.
  bool get hasBrands => available && brands.isNotEmpty;

  /// The services the cashier can sell right now.
  List<VoucherMenuService> get sellableServices => [
    for (final service in services)
      if (service.isSellable) service,
  ];

  /// Whether the menu offers any direct service.
  bool get hasServices => available && sellableServices.isNotEmpty;

  /// The airtime card, when airtime can be sold.
  VoucherMenuService? get airtimeService {
    for (final service in sellableServices) {
      if (service.kind == ServiceKind.airtime) {
        return service;
      }
    }
    return null;
  }

  /// One card per type of bill that has a provider, electricity first.
  List<VoucherMenuService> get billServices {
    final bills = [
      for (final service in sellableServices)
        if (service.kind == ServiceKind.bill && service.billType.isOffered)
          service,
    ];
    return bills..sort(
      (a, b) => a.billType.displayOrder.compareTo(b.billType.displayOrder),
    );
  }

  /// Whether the menu offers bill payments of any type.
  bool get hasBills => billServices.isNotEmpty;

  /// The categories that hold at least one brand, in display order: a tab
  /// that opens on nothing is worse than no tab.
  List<VoucherMenuCategory> get usedCategories {
    final used = {for (final brand in brands) brand.category};
    return [
      for (final category in categories)
        if (used.contains(category.key)) category,
    ];
  }

  /// The brands of one category, in display order; every brand for null.
  List<VoucherBrand> brandsIn(String? categoryKey) {
    if (categoryKey == null) {
      return brands;
    }
    return [
      for (final brand in brands)
        if (brand.category == categoryKey) brand,
    ];
  }

  /// The country [code] names, or a bare one when the server listed none.
  VoucherCountry country(String code) {
    for (final country in countries) {
      if (country.code == code) {
        return country;
      }
    }
    return VoucherCountry(code: code);
  }

  /// The brand whose system product is [productId] — what lets a card found
  /// by searching open the same sheet as one picked off the menu.
  VoucherBrand? brandForProduct(int productId) {
    for (final brand in brands) {
      if (brand.product?.id == productId) {
        return brand;
      }
    }
    return null;
  }
}

class VoucherMenuCategory {
  const VoucherMenuCategory({required this.key, this.name = ''});

  factory VoucherMenuCategory.fromJson(Map<String, Object?> json) {
    return VoucherMenuCategory(
      key: _string(json['key']),
      name: _string(json['name']),
    );
  }

  final String key;
  final String name;

  String get label => name.isNotEmpty ? name : key;
}

/// One direct service the company sells, as the menu lists it: airtime, or one
/// type of bill. The server sends keys and counts only — the names, the
/// promises and the art are the till's own.
class VoucherMenuService {
  const VoucherMenuService({
    required this.key,
    required this.kind,
    this.billType = BillType.other,
    this.available = false,
    this.variantId = 0,
    this.countries = 0,
    this.providers = 0,
    this.testMode = false,
  });

  factory VoucherMenuService.fromJson(Map<String, Object?> json) {
    final key = _string(json['key']);
    // `bill:electricity` names its type even if a server forgets the fields.
    final colon = key.indexOf(':');
    final kind =
        serviceKindFromJson(json['kind']) ??
        serviceKindFromJson(colon < 0 ? key : key.substring(0, colon));
    return VoucherMenuService(
      key: key,
      kind: kind ?? ServiceKind.airtime,
      billType: billTypeFromJson(
        json['bill_type'] ?? (colon < 0 ? null : key.substring(colon + 1)),
      ),
      // Absent is not "on sale": a service bought only once the invoice is
      // paid must never be offered on a guess.
      available: kind != null && json['available'] == true,
      variantId: _int(json['variant_id']),
      countries: _int(json['countries']),
      providers: _int(json['providers']),
      testMode: json['test_mode'] == true,
    );
  }

  /// `airtime`, `bill:electricity`, `bill:water`, `bill:tv`, `bill:internet`.
  final String key;
  final ServiceKind kind;

  /// What a bill card pays; meaningless for airtime.
  final BillType billType;
  final bool available;

  /// The system service product the cart line points at. All bill types share
  /// one.
  final int variantId;

  /// How many countries and providers stand behind the card, for its caption.
  final int countries;
  final int providers;

  /// Sold from the relay's test supplier: fake money, nothing really sent.
  final bool testMode;

  /// A cashier can sell it: switched on, and the product to put in the cart
  /// exists.
  bool get isSellable => available && variantId > 0;
}

/// A country a card is for: iTunes US is not iTunes UK.
class VoucherCountry {
  const VoucherCountry({required this.code, this.name = '', this.flag});

  factory VoucherCountry.fromJson(Map<String, Object?> json) {
    return VoucherCountry(
      code: _string(json['code']).toUpperCase(),
      name: _string(json['name']),
      flag: decodeVoucherImage(json['flag']),
    );
  }

  /// ISO 3166 alpha-2, or `WW` (worldwide) and `EU`.
  final String code;

  /// Arabic, from the relay.
  final String name;

  /// The flag as PNG bytes, decoded once here. Kept as one instance for the
  /// life of the menu, so the image cache recognises it on every rebuild.
  final Uint8List? flag;

  String get label => name.isNotEmpty ? name : code;
}

/// One brand on the menu — iTunes, PlayStation, Libyana — and its cards.
class VoucherBrand {
  VoucherBrand({
    required this.key,
    required this.name,
    this.category = '',
    this.featured = false,
    this.badge = '',
    this.hasPromo = false,
    this.redeemHint = '',
    this.aliases = const [],
    this.product,
    this.items = const [],
  });

  factory VoucherBrand.fromJson(Map<String, Object?> json) {
    return VoucherBrand(
      key: _string(json['key']),
      name: _string(json['name']),
      category: _string(json['category']),
      featured: json['featured'] == true,
      badge: _string(json['badge']),
      hasPromo: json['has_promo'] == true,
      redeemHint: _string(json['redeem_hint']),
      aliases: _strings(json['aliases']),
      product: _product(json['product']),
      items: _list(
        json['items'],
        VoucherItem.fromJson,
      ).where((item) => item.key.isNotEmpty).toList(growable: false),
    );
  }

  final String key;
  final String name;

  /// The key of its [VoucherMenuCategory].
  final String category;

  /// Pushed to the front by the company.
  final bool featured;

  /// The brand's own label ("الأكثر مبيعاً"), blank when it has none.
  final String badge;

  /// The server says a promotion runs on one of its cards.
  final bool hasPromo;

  /// Where the customer redeems it, in one line.
  final String redeemHint;

  /// Other names a cashier may type for it («Visa» for the prepaid
  /// Mastercard); empty from a server that sends none.
  final List<String> aliases;

  /// The system product its cards are variants of. Null only from a broken
  /// payload — and then nothing of the brand can be sold.
  final Product? product;

  /// In display order.
  final List<VoucherItem> items;

  late final Map<int, ProductVariant> _variants = {
    for (final variant in product?.activeVariants ?? const <ProductVariant>[])
      variant.id: variant,
  };

  String get displayName {
    if (name.isNotEmpty) {
      return name;
    }
    final productName = product?.name.trim() ?? '';
    return productName.isNotEmpty ? productName : key;
  }

  /// The card art for the till, or null when the company uploaded none.
  String? get logoUrl {
    final url = product?.primaryImage?.contentUrl.trim() ?? '';
    return url.isEmpty ? null : url;
  }

  /// The countries its cards are for, in the order its cards come.
  List<String> get countryCodes {
    final seen = <String>{};
    return [
      for (final item in items)
        if (item.country.isNotEmpty && seen.add(item.country)) item.country,
    ];
  }

  /// The cards for one country; every card for null.
  List<VoucherItem> itemsFor(String? country) {
    if (country == null) {
      return items;
    }
    return [
      for (final item in items)
        if (item.country == country) item,
    ];
  }

  /// The variant a cart line for [item] points at — the brand's own system
  /// product's, so the line's name and price are the server's. Null when it
  /// is not (or no longer) sellable.
  ProductVariant? variantFor(VoucherItem item) => _variants[item.variantId];

  /// Whether a cashier can sell [item] now.
  bool canSell(VoucherItem item) => item.available && variantFor(item) != null;

  /// Whether any of its cards can be sold now.
  bool get isAvailable => items.any(canSell);

  /// Whether a promotion runs on any of its cards.
  bool get onPromo => hasPromo || items.any((item) => item.isOnPromo);

  /// What its promotion is called, by the card that has one — null for the
  /// till's default word.
  String? get promoBadge {
    String? fallback;
    for (final item in items) {
      if (item.badge.isEmpty || !item.isOnPromo) {
        continue;
      }
      if (canSell(item)) {
        return item.badge;
      }
      fallback ??= item.badge;
    }
    return fallback;
  }

  /// The cheapest and dearest card on sale now — of every card when none is.
  ({double min, double max})? get priceRange {
    final selling = items.where(canSell).toList(growable: false);
    final pool = selling.isEmpty ? items : selling;
    if (pool.isEmpty) {
      return null;
    }
    var min = pool.first.price;
    var max = pool.first.price;
    for (final item in pool.skip(1)) {
      if (item.price < min) min = item.price;
      if (item.price > max) max = item.price;
    }
    return (min: min, max: max);
  }
}

/// One card: a brand's denomination for one country.
class VoucherItem {
  const VoucherItem({
    required this.variantId,
    required this.key,
    required this.price,
    this.label = '',
    this.name = '',
    this.country = '',
    this.faceValue = '',
    this.faceCurrency = '',
    this.regularPrice,
    this.badge = '',
    this.promoEndsAt,
    this.available = false,
    this.exceedsFloat = false,
    this.cost,
  });

  factory VoucherItem.fromJson(Map<String, Object?> json) {
    return VoucherItem(
      variantId: _int(json['variant_id']),
      key: _string(json['key']),
      label: _string(json['label']),
      name: _string(json['name']),
      country: _string(json['country']).toUpperCase(),
      faceValue: _string(json['face_value']),
      faceCurrency: _string(json['face_currency']),
      price: _amountOrNull(json['price']) ?? 0,
      regularPrice: _amountOrNull(json['regular_price']),
      badge: _string(json['badge']),
      promoEndsAt: _date(json['promo_ends_at']),
      // Absent is not "on sale": a card bought only once the invoice is paid
      // must never be offered on a guess.
      available: json['available'] == true,
      exceedsFloat: json['exceeds_float'] == true,
      cost: _amountOrNull(json['cost']),
    );
  }

  /// The variant of the brand's product a cart line points at.
  final int variantId;
  final String key;

  /// The face value as the customer reads it: "10 دولار".
  final String label;

  /// The variant's name: "الولايات المتحدة · 10 دولار".
  final String name;
  final String country;
  final String faceValue;
  final String faceCurrency;

  /// What the customer pays — what checkout will charge.
  final double price;

  /// The price without the promotion, when one runs.
  final double? regularPrice;

  /// The promotion's label ("عرض"), blank when none runs.
  final String badge;
  final DateTime? promoEndsAt;

  /// Sellable right now: in stock with the company's supplier.
  final bool available;

  /// The voucher balance, as last read, cannot pay for this card. Decided by
  /// the server, so the till can warn without being told the cost.
  final bool exceedsFloat;

  /// What the card costs the shop. Only a reader with full visibility is
  /// sent it; absent for everyone else, never zero.
  final double? cost;

  String get displayLabel {
    if (label.isNotEmpty) return label;
    if (name.isNotEmpty) return name;
    return key;
  }

  /// Cheaper than its regular price.
  bool get isDiscounted {
    final regular = regularPrice;
    return regular != null && regular > price + 0.004;
  }

  bool get isOnPromo => isDiscounted || badge.isNotEmpty;

  /// What the shop earns on one, when the reader may know the cost.
  double? get profit {
    final cost = this.cost;
    return cost == null ? null : price - cost;
  }
}

/// A base64 PNG off the wire (bare, or as a data URL) as bytes; null when
/// absent or unreadable.
Uint8List? decodeVoucherImage(Object? raw) {
  if (raw is! String) {
    return null;
  }
  var text = raw.trim();
  if (text.isEmpty) {
    return null;
  }
  final comma = text.indexOf(',');
  if (text.startsWith('data:') && comma != -1) {
    text = text.substring(comma + 1);
  }
  try {
    final bytes = base64Decode(base64.normalize(text));
    return bytes.isEmpty ? null : bytes;
  } on FormatException {
    return null;
  }
}

Product? _product(Object? raw) {
  if (raw is! Map<String, Object?>) {
    return null;
  }
  try {
    return Product.fromJson(raw);
  } on Object {
    // One malformed product loses its brand, not the menu.
    return null;
  }
}

List<T> _list<T>(Object? raw, T Function(Map<String, Object?>) parse) {
  if (raw is! List) {
    return const [];
  }
  final parsed = <T>[];
  for (final entry in raw) {
    if (entry is! Map<String, Object?>) {
      continue;
    }
    try {
      parsed.add(parse(entry));
    } on Object {
      continue;
    }
  }
  return parsed;
}

/// A list of non-empty strings; anything else is an empty list.
List<String> _strings(Object? raw) {
  if (raw is! List) {
    return const [];
  }
  return [
    for (final entry in raw)
      if (entry != null && entry.toString().trim().isNotEmpty)
        entry.toString().trim(),
  ];
}

String _string(Object? raw) => raw == null ? '' : raw.toString().trim();

int _int(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '') ?? 0;
}

double? _amountOrNull(Object? raw) {
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw.trim());
  return null;
}

DateTime? _date(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) {
    return null;
  }
  return DateTime.tryParse(raw.trim())?.toLocal();
}
