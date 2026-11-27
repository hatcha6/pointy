import '../../core/money.dart';
import 'catalog.dart';
import 'json.dart';

/// The category a bundle's stand-in brand carries ([CardBundle.asBrand]):
/// its art is its cards' own arts joined, and it is never on a category's
/// shelf.
const String bundleCategory = 'bundle';

/// The key a bundle's stand-in brand and its orders carry: "bundle:gamer".
String bundleBrandKey(String bundle) => 'bundle:$bundle';

/// The bundle a brand key names, or empty for a brand.
String bundleOfBrandKey(String brand) =>
    brand.startsWith('bundle:') ? brand.substring(7) : '';

/// Two or more cards bought together for less (`bundles` in the catalog):
/// a PUBG top-up with the phone credit of the buyer's own network.
///
/// The company sets every amount. A tier fixes what each part is; the buyer
/// picks the tier and, where a part offers several cards of one value (one
/// per network), which of them is theirs. A bundle never takes a segment
/// offer, is bought one at a time, and its cards stay on the shelf on their
/// own at their own prices.
class CardBundle {
  const CardBundle({
    required this.key,
    required this.name,
    required this.tagline,
    required this.rank,
    required this.tiers,
    this.art = const {},
  });

  factory CardBundle.fromJson(Map<String, dynamic> json) => CardBundle(
    key: readString(json, 'key'),
    name: readString(json, 'name'),
    tagline: readString(json, 'tagline'),
    rank: readInt(json, 'rank'),
    tiers: [
      for (final tier in readList(json, 'tiers')) BundleTier.fromJson(tier),
    ],
    art: {
      for (final MapEntry(:key, :value) in readMap(json, 'art').entries)
        if (value is String && value.isNotEmpty) key: value,
    },
  );

  final String key;
  final String name;

  /// What is in it, in a line: «شدّات ببجي مع رصيد هاتفك».
  final String tagline;
  final int rank;
  final List<BundleTier> tiers;

  /// The bundle's artwork (image references, as a brand's `logo`), one per
  /// choice: keyed by the brands picked in the parts the buyer picks in,
  /// joined by commas ("libyana"); "" for the one shown when none fits.
  final Map<String, String> art;

  String get brandKey => bundleBrandKey(key);
}

/// One size of a bundle: its parts and what buying them together saves.
class BundleTier {
  const BundleTier({
    required this.key,
    required this.saving,
    required this.parts,
  });

  factory BundleTier.fromJson(Map<String, dynamic> json) => BundleTier(
    key: readString(json, 'key'),
    saving: Money.parse(readString(json, 'saving')),
    parts: [
      for (final part in (json['parts'] as List? ?? const []))
        if (part is List) [for (final item in part) ?_itemKey(item)],
    ],
  );

  static String? _itemKey(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  final String key;

  /// Taken off the cards' own prices added up.
  final Money saving;

  /// The item keys of each part: one for a part the company fixed, several
  /// for a part the buyer picks one of.
  final List<List<String>> parts;
}

/// A card in a bundle, found on the shelf.
typedef BundleCard = ({CardBrand brand, CardItem item});

/// A bundle as this shelf can sell it: every part found on the shelf, on
/// sale, and a code (a card sent to an account, or one bought on the
/// website only, is not bundled). A tier missing a part is left off, and a
/// bundle with no tier left is not shown.
class ShelfBundle {
  const ShelfBundle._(this.bundle, this.tiers);

  final CardBundle bundle;
  final List<ShelfTier> tiers;

  static ShelfBundle? resolve(CardBundle bundle, CardCatalog shelf) {
    final tiers = [
      for (final tier in bundle.tiers) ?ShelfTier._resolve(tier, shelf),
    ];
    return tiers.isEmpty ? null : ShelfBundle._(bundle, tiers);
  }

  String get key => bundle.key;
  String get name => bundle.name;
  String get tagline => bundle.tagline;

  /// The parts the buyer picks in (those defined with several cards), by
  /// their place: every brand any size offers there, in order.
  Map<int, List<CardBrand>> get choices {
    final out = <int, List<CardBrand>>{};
    for (final tier in tiers) {
      for (final (index, part) in tier.parts.indexed) {
        if (tier.tier.parts[index].length < 2) {
          continue;
        }
        final brands = out.putIfAbsent(index, () => []);
        for (final card in part) {
          if (!brands.any((brand) => brand.key == card.brand.key)) {
            brands.add(card.brand);
          }
        }
      }
    }
    return out;
  }

  /// The size the page opens on: the middle one, which most buyers take.
  ShelfTier get defaultTier => tiers[(tiers.length - 1) ~/ 2];

  /// The brands picked by default: the default size's first of each part.
  List<String> get defaultPick => defaultTier.firstPick;

  /// Whether [tier] has a card for every brand in [pick] where the buyer
  /// picks: a size without the buyer's network is not theirs to buy, and
  /// is never quietly sold with another network's card.
  bool offers(ShelfTier tier, List<String> pick) {
    for (final index in choices.keys) {
      if (index >= pick.length || index >= tier.parts.length) {
        continue;
      }
      if (!tier.parts[index].any((card) => card.brand.key == pick[index])) {
        return false;
      }
    }
    return true;
  }

  /// The size nearest [from] that [pick] can be bought in, or null.
  ShelfTier? nearestOffering(ShelfTier from, List<String> pick) {
    if (offers(from, pick)) {
      return from;
    }
    final at = tiers.indexOf(from);
    final ranked = [...tiers]
      ..sort(
        (a, b) => (tiers.indexOf(a) - at).abs() - (tiers.indexOf(b) - at).abs(),
      );
    return ranked.where((tier) => offers(tier, pick)).firstOrNull;
  }

  /// The most a tier saves, for the shelf's badge.
  Money get bestSaving => tiers
      .map((tier) => tier.tier.saving)
      .reduce((a, b) => a.compareTo(b) >= 0 ? a : b);

  /// What the cheapest size starts at, each with its own first cards.
  Money get fromPrice => tiers
      .map((tier) => tier.price(tier.firstPick))
      .reduce((a, b) => a.compareTo(b) <= 0 ? a : b);

  /// The artwork for [pick] (brand keys by part): the one for the brands
  /// picked where the buyer picks, else one for any brand picked, else the
  /// bundle's own.
  String artFor(List<String> pick) {
    final picked = [
      for (final index in choices.keys)
        if (index < pick.length) pick[index],
    ];
    return bundle.art[picked.join(',')] ??
        [for (final key in pick) ?bundle.art[key]].firstOrNull ??
        bundle.art[''] ??
        bundle.art.values.firstOrNull ??
        '';
  }

  ShelfTier? tier(String key) =>
      tiers.where((tier) => tier.tier.key == key).firstOrNull;

  /// The bundle as a brand, so its art, checkout, order and codes go
  /// through the pages every card does: its art is the artwork for [pick]
  /// (brand keys by part), its cards are its tiers.
  CardBrand asBrand([List<String>? pick]) => CardBrand(
    key: bundle.brandKey,
    name: bundle.name,
    aliases: const [],
    category: bundleCategory,
    rank: bundle.rank,
    featured: false,
    badge: '',
    redeemHint: '',
    logo: artFor(pick ?? defaultPick),
    items: [for (final tier in tiers) tier.asItem(pick ?? defaultPick)],
  );
}

/// A tier as the shelf has it: each part's cards found.
class ShelfTier {
  const ShelfTier._(this.tier, this.parts);

  static ShelfTier? _resolve(BundleTier tier, CardCatalog shelf) {
    if (tier.parts.length < 2) {
      return null;
    }
    final parts = <List<BundleCard>>[];
    for (final keys in tier.parts) {
      final cards = [for (final key in keys) ?_sellable(shelf, key)];
      if (cards.isEmpty) {
        return null;
      }
      parts.add(cards);
    }
    // Never sold at or under nothing.
    final cheapest = parts.fold(
      Money.zero,
      (sum, part) =>
          sum +
          part
              .map((card) => card.item.price)
              .reduce((a, b) => a.compareTo(b) <= 0 ? a : b),
    );
    if (tier.saving.dirhams < 0 || tier.saving.compareTo(cheapest) >= 0) {
      return null;
    }
    return ShelfTier._(tier, parts);
  }

  static BundleCard? _sellable(CardCatalog shelf, String itemKey) {
    for (final brand in shelf.brands) {
      if (brand.toAccount || brand.webOnly) {
        continue;
      }
      for (final item in brand.items) {
        if (item.key == itemKey) {
          return item.available ? (brand: brand, item: item) : null;
        }
      }
    }
    return null;
  }

  final BundleTier tier;
  final List<List<BundleCard>> parts;

  /// Each part's first card's brand: this size bought as it comes.
  List<String> get firstPick => [
    for (final part in parts) part.first.brand.key,
  ];

  /// The card each part comes to with [pick] (brand keys by part): the
  /// picked brand's, else the part's first.
  List<BundleCard> cards(List<String> pick) => [
    for (final (index, part) in parts.indexed)
      part.firstWhere(
        (card) => index < pick.length && card.brand.key == pick[index],
        orElse: () => part.first,
      ),
  ];

  /// The cards bought apart.
  Money apart(List<String> pick) =>
      cards(pick).fold(Money.zero, (sum, card) => sum + card.item.price);

  /// What the bundle costs: the cards apart, less the saving.
  Money price(List<String> pick) => apart(pick) - tier.saving;

  /// «60 شدة + 5 دينار».
  String label(List<String> pick) =>
      cards(pick).map((card) => card.item.label).join(' + ');

  CardItem asItem(List<String> pick) => CardItem(
    key: tier.key,
    country: '',
    label: label(pick),
    faceValue: '',
    faceCurrency: '',
    price: price(pick),
    regularPrice: apart(pick),
    promoBadge: '',
    available: true,
    rank: 0,
  );
}
