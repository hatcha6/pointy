import 'package:flutter/foundation.dart';

/// A place in the app that a web address names: what an ad, a message or a
/// QR code points at. The same address opens the app on a phone that has it
/// (Universal Links, App Links) and the web build everywhere else.
///
/// | Address                            | Opens                                |
/// | ---------------------------------- | ------------------------------------ |
/// | `/`                                | the shelf                            |
/// | `/category/gaming`                 | the shelf on one category            |
/// | `/search?q=ببجي`                    | the shelf searching                  |
/// | `/brand/pubg`                      | a brand's page                       |
/// | `/brand/pubg?item=pubg-325`        | a brand's page on one card           |
/// | `/my-cards`, `/account`            | the other two tabs                   |
/// | `/esim`                            | the eSIM shelf                       |
/// | `/esim?days=30&gb=5&offers=1`      | the eSIM shelf, filtered             |
/// | `/esim/turkey`                     | a destination's eSIM plans           |
/// | `/esim/turkey/ea.PTR1G7`           | one plan, open over its destination  |
/// | `/esims/8944…`                     | one of the customer's eSIMs          |
/// | `/privacy`, `/terms`, `/about`     | the legal pages and «عن التطبيق»       |
///
/// Anything else (an old or mistyped address) opens the shelf. Extra query
/// parameters, such as an ad's `utm_*`, are ignored.
@immutable
sealed class CardsLink {
  const CardsLink();

  /// The official address every link is written with.
  static final Uri origin = Uri.parse('https://cards.dftr.ly');

  /// The place [uri] names. Only its path and query are read: the host was
  /// already checked by the phone (only `cards.dftr.ly` reaches the app) or
  /// is the web build's own.
  static CardsLink parse(Uri uri) {
    final segments = [
      for (final segment in uri.pathSegments)
        if (segment.isNotEmpty) segment,
    ];
    final query = uri.queryParameters;
    String? second() => segments.length > 1 ? segments[1] : null;
    return switch (segments.firstOrNull) {
      'category' when second() != null => ShelfLink(category: second()),
      'search' when (query['q'] ?? '').trim().isNotEmpty => ShelfLink(
        query: query['q']!.trim(),
      ),
      'brand' when second() != null => BrandLink(
        second()!,
        item: (query['item'] ?? '').isEmpty ? null : query['item'],
      ),
      'my-cards' when second() != null => OrderLink(second()!),
      'my-cards' => const TabLink(CardsTab.myCards),
      'account' => const TabLink(CardsTab.account),
      'esim' => EsimShelfLink(
        destination: second(),
        plan: segments.length > 2 ? segments[2] : null,
        query: second() == null ? (query['q'] ?? '').trim() : '',
        kind: second() == null ? (query['kind'] ?? '') : '',
        days: second() == null ? int.tryParse(query['days'] ?? '') ?? 0 : 0,
        gb: second() == null ? int.tryParse(query['gb'] ?? '') ?? 0 : 0,
        offers: second() == null && query['offers'] == '1',
        cheapest: second() == null && query['sort'] == 'cheapest',
      ),
      'esims' when second() != null => EsimLink(second()!),
      'esims' => const TabLink(CardsTab.myCards),
      'privacy' => const PageLink(LinkedPage.privacy),
      'terms' => const PageLink(LinkedPage.terms),
      'about' => const PageLink(LinkedPage.about),
      _ => const ShelfLink(),
    };
  }

  /// The path and query, as the app's own routes and the browser show it.
  String get location;

  /// The full address to share.
  Uri get uri => origin.resolve(location);
}

/// The shelf, plain, on one category, or searching.
final class ShelfLink extends CardsLink {
  const ShelfLink({this.category, this.query});

  final String? category;
  final String? query;

  @override
  String get location {
    if (query != null) {
      return Uri(path: '/search', queryParameters: {'q': query}).toString();
    }
    if (category != null) {
      return '/category/${Uri.encodeComponent(category!)}';
    }
    return '/';
  }

  @override
  bool operator ==(Object other) =>
      other is ShelfLink && other.category == category && other.query == query;

  @override
  int get hashCode => Object.hash(category, query);
}

final class BrandLink extends CardsLink {
  const BrandLink(this.brand, {this.item});

  final String brand;

  /// The card to start on, when the link names one.
  final String? item;

  @override
  String get location {
    final path = '/brand/${Uri.encodeComponent(brand)}';
    return item == null
        ? path
        : Uri(path: path, queryParameters: {'item': item}).toString();
  }

  @override
  bool operator ==(Object other) =>
      other is BrandLink && other.brand == brand && other.item == item;

  @override
  int get hashCode => Object.hash(brand, item);
}

/// The shell's three tabs, in the tab bar's order.
enum CardsTab { shelf, myCards, account }

final class TabLink extends CardsLink {
  const TabLink(this.tab);

  final CardsTab tab;

  @override
  String get location => switch (tab) {
    CardsTab.shelf => '/',
    CardsTab.myCards => '/my-cards',
    CardsTab.account => '/account',
  };

  @override
  bool operator ==(Object other) => other is TabLink && other.tab == tab;

  @override
  int get hashCode => tab.hashCode;
}

/// One order in «كروتي»: its card's code, or the order still on its way.
/// The relay's notification about a late card opens this.
final class OrderLink extends CardsLink {
  const OrderLink(this.order);

  final String order;

  @override
  String get location => '/my-cards/${Uri.encodeComponent(order)}';

  @override
  bool operator ==(Object other) => other is OrderLink && other.order == order;

  @override
  int get hashCode => order.hashCode;
}

/// The eSIM shelf, one destination on it, or one plan of a destination. The
/// shelf's own link can carry what it opens on: a search (`q`), a tab (`kind`:
/// regional, global), a trip (`days`, `gb`), only offers (`offers=1`), and the
/// cheapest first (`sort=cheapest`).
final class EsimShelfLink extends CardsLink {
  const EsimShelfLink({
    this.destination,
    this.plan,
    this.query = '',
    this.kind = '',
    this.days = 0,
    this.gb = 0,
    this.offers = false,
    this.cheapest = false,
  });

  final String? destination;

  /// A plan's id at [destination]: its sheet opens over the destination.
  final String? plan;
  final String query;
  final String kind;
  final int days;
  final int gb;
  final bool offers;
  final bool cheapest;

  @override
  String get location {
    if (destination != null) {
      final page = '/esim/${Uri.encodeComponent(destination!)}';
      return plan == null ? page : '$page/${Uri.encodeComponent(plan!)}';
    }
    final asked = {
      if (query.isNotEmpty) 'q': query,
      if (kind == 'regional' || kind == 'global') 'kind': kind,
      if (days > 0) 'days': '$days',
      if (gb > 0) 'gb': '$gb',
      if (offers) 'offers': '1',
      if (cheapest) 'sort': 'cheapest',
    };
    return asked.isEmpty
        ? '/esim'
        : Uri(path: '/esim', queryParameters: asked).toString();
  }

  @override
  bool operator ==(Object other) =>
      other is EsimShelfLink && other.location == location;

  @override
  int get hashCode => location.hashCode;
}

/// One eSIM the customer bought: a low-data alert opens this, to top up.
final class EsimLink extends CardsLink {
  const EsimLink(this.iccid);

  final String iccid;

  @override
  String get location => '/esims/${Uri.encodeComponent(iccid)}';

  @override
  bool operator ==(Object other) => other is EsimLink && other.iccid == iccid;

  @override
  int get hashCode => iccid.hashCode;
}

enum LinkedPage { privacy, terms, about }

final class PageLink extends CardsLink {
  const PageLink(this.page);

  final LinkedPage page;

  @override
  String get location => '/${page.name}';

  @override
  bool operator ==(Object other) => other is PageLink && other.page == page;

  @override
  int get hashCode => page.hashCode;
}
