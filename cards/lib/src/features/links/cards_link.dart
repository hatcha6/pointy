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
      'my-cards' => const TabLink(CardsTab.myCards),
      'account' => const TabLink(CardsTab.account),
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
