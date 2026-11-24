import 'package:flutter/foundation.dart';

import '../../core/analytics/analytics.dart';
import '../../core/analytics/events.dart';
import '../../core/result.dart';
import '../../data/api/relay_api.dart';
import '../../data/models/catalog.dart';
import '../../data/models/json.dart';
import '../../data/models/offer.dart';

/// The offers the app shows: this customer's (`/v1/customers/me/offers`),
/// or, before signing in, the ones for everyone (`/v1/customers/offers`).
/// Every badge, banner and checkout reads them here, so they agree.
class OffersModel extends ChangeNotifier {
  OffersModel({
    required this.api,
    required this.isSignedIn,
    required this.analytics,
  });

  final RelayApi api;
  final bool Function() isSignedIn;
  final Analytics analytics;

  List<CardOffer> _offers = const [];
  List<CardOffer> get offers => _offers;

  /// Whether those offers are the customer's own (they can use them now) or
  /// the public ones (they sign in first).
  bool signedIn = false;

  Future<void>? _loading;
  bool _asked = false;

  /// Reads them once if nothing has yet: a page opened straight from a link
  /// shows its offer without waiting for the shelf.
  void ensureLoaded() {
    if (!_asked) {
      refresh();
    }
  }

  /// Reads them again: at launch, on signing in or out, after an order.
  Future<void> refresh() {
    _asked = true;
    return _loading ??= _refresh().whenComplete(() => _loading = null);
  }

  Future<void> _refresh() async {
    final mine = isSignedIn();
    final result = await Result.guard(() async {
      final answer = mine
          ? await api.get('/v1/customers/me/offers', signedIn: true)
          : await api.get('/v1/customers/offers');
      return [
        for (final raw in readList(answer, 'offers')) ?CardOffer.fromJson(raw),
      ];
    });
    // Without them nothing is wrong: the shelf simply shows no offers.
    if (result case Ok(:final value)) {
      _offers = value;
      signedIn = mine;
      notifyListeners();
    }
  }

  /// Forgets them (a customer signed out): what was given to one is never
  /// shown to the next.
  void forget() {
    _offers = const [];
    signedIn = false;
    notifyListeners();
  }

  /// The offer to show on [brand]: the best for one of its cards, at one
  /// card. Null when none covers it.
  CardOffer? forBrand(CardBrand brand) {
    CardOffer? best;
    var most = -1;
    for (final offer in _offers) {
      for (final item in brand.items) {
        if (!item.available) {
          continue;
        }
        final line = lineFor(brand, item, 1);
        // A bundle or a minimum takes more than one card: shown all the same.
        final off = offer.discountOn(line).dirhams;
        final covers = offer.scope.covers(
          category: brand.category,
          brand: brand.key,
          item: item.key,
        );
        if (covers && off > most) {
          best = offer;
          most = off;
        }
      }
    }
    return best;
  }

  /// The offer covering [item] of [brand], the best at one card.
  CardOffer? forItem(CardBrand brand, CardItem item) {
    CardOffer? best;
    var most = -1;
    for (final offer in _offers) {
      if (!offer.scope.covers(
        category: brand.category,
        brand: brand.key,
        item: item.key,
      )) {
        continue;
      }
      final off = offer.discountOn(lineFor(brand, item, 1)).dirhams;
      if (off > most) {
        best = offer;
        most = off;
      }
    }
    return best;
  }

  /// The offer covering eSIMs, the best for a plan of [price].
  CardOffer? forCategory(String category) =>
      _offers.where((o) => o.scope.covers(category: category)).firstOrNull;

  /// [item] of [brand], [quantity] of it, as an offer prices it.
  static OfferLine lineFor(CardBrand brand, CardItem item, int quantity) =>
      OfferLine(
        unitPrice: item.price,
        quantity: quantity,
        category: brand.category,
        brand: brand.key,
        item: item.key,
      );

  final Set<String> _seen = {};

  /// Tells analytics an offer came on screen on [surface], once a session.
  void seen(CardOffer offer, String surface) {
    if (_seen.add('${offer.id}/$surface')) {
      analytics.offerSeen(offer, surface);
    }
  }
}
