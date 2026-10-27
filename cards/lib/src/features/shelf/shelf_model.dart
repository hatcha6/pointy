import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/arabic_search.dart';
import '../../core/money.dart';
import '../../core/result.dart';
import '../../data/models/catalog.dart';
import '../../data/models/order.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/catalog_repository.dart';
import '../../data/repositories/orders_repository.dart';
import '../../core/analytics/events.dart';

/// One card the customer bought before and can buy again in one tap.
typedef BuyAgain = ({CardBrand brand, CardItem item});

/// The shelf: the catalog (the saved copy at once, then the relay's), search,
/// the category filter, and for a signed-in customer their credit and what
/// they bought before.
class ShelfModel extends ChangeNotifier {
  ShelfModel({required this.catalog, required this.orders, required this.auth});

  final CatalogRepository catalog;
  final OrdersRepository orders;
  final AuthRepository auth;

  CardCatalog shelf = CardCatalog.empty;
  bool loading = true;

  /// The relay could not be reached; [shelf] is the saved copy (or empty).
  bool offline = false;
  String query = '';
  String? category;
  Money credit = Money.zero;
  List<CardOrder> history = const [];

  Future<void> load() async {
    final saved = await catalog.cached();
    if (saved != null) {
      shelf = saved;
      loading = false;
      notifyListeners();
    }
    await refresh();
  }

  Future<void> refresh() async {
    final result = await catalog.refresh();
    switch (result) {
      case Ok(:final value):
        shelf = value;
        offline = false;
      case Error():
        offline = true;
    }
    loading = false;
    notifyListeners();
    await refreshCustomer();
  }

  /// Credit and history, when someone is signed in.
  Future<void> refreshCustomer() async {
    if (!auth.isSignedIn) {
      credit = Money.zero;
      history = const [];
      notifyListeners();
      return;
    }
    final results = await Future.wait([orders.credit(), orders.orders()]);
    if (results[0] case Ok(:final value)) {
      credit = (value as CreditStatement).balance;
    }
    if (results[1] case Ok(:final value)) {
      history = value as List<CardOrder>;
    }
    notifyListeners();
  }

  void search(String text) {
    query = text;
    notifyListeners();
    _searched?.cancel();
    final typed = text.trim();
    if (typed.isEmpty) {
      return;
    }
    // Told once the customer stops typing, not at every letter.
    _searched = Timer(const Duration(milliseconds: 1200), () {
      orders.analytics.searched(typed, find(typed).length);
    });
  }

  Timer? _searched;

  void filter(String? key) {
    if (key != null && key != category) {
      orders.analytics.categorySelected(key);
    }
    category = key;
    notifyListeners();
  }

  @override
  void dispose() {
    _searched?.cancel();
    super.dispose();
  }

  bool get searching => query.trim().isNotEmpty;

  /// The brands to show: the category's (or all), matching the search, the
  /// featured first, then by the catalog's own order.
  List<CardBrand> get brands =>
      find(query, category: searching ? null : category);

  /// The brands matching [text] (all when it is empty), in [category] when
  /// one is given, the featured first, then by the catalog's own order.
  List<CardBrand> find(String text, {String? category}) {
    final names = {for (final c in shelf.categories) c.key: c.name};
    final list = shelf.brands.where((brand) {
      if (category != null && brand.category != category) {
        return false;
      }
      return matchesSearch(text, [
        brand.name,
        ...brand.aliases,
        names[brand.category] ?? '',
        for (final item in brand.items) item.label,
      ]);
    }).toList();
    list.sort((a, b) {
      if (a.featured != b.featured) {
        return a.featured ? -1 : 1;
      }
      return a.rank.compareTo(b.rank);
    });
    return list;
  }

  /// Up to six cards bought before that are still on the shelf, newest first.
  List<BuyAgain> get buyAgain {
    final seen = <String>{};
    final out = <BuyAgain>[];
    for (final order in history) {
      if (order.status != OrderStatus.delivered || !seen.add(order.itemKey)) {
        continue;
      }
      final brand = shelf.brand(order.brandKey);
      final item = brand?.items
          .where((i) => i.key == order.itemKey)
          .firstOrNull;
      if (brand != null && item != null && item.available) {
        out.add((brand: brand, item: item));
      }
      if (out.length == 6) {
        break;
      }
    }
    return out;
  }
}
