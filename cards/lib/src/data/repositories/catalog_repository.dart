import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/result.dart';
import '../api/relay_api.dart';
import '../models/bundle.dart';
import '../models/catalog.dart';
import '../models/order.dart';

/// The card shelf, kept on the device so the app opens on it at once and
/// still shows it offline. A refresh sends the stored ETag: a shelf that did
/// not change costs a 304 and no download.
class CatalogRepository {
  CatalogRepository({
    required this.api,
    required this.channel,
    this.preferences,
  });

  final RelayApi api;
  final String channel;
  final SharedPreferencesAsync? preferences;
  CardCatalog? _current;

  String get _bodyKey => 'cards.catalog.$channel.body';
  String get _etagKey => 'cards.catalog.$channel.etag';

  /// The last shelf this device saw, or null on a first launch.
  Future<CardCatalog?> cached() async {
    if (_current != null) {
      return _current;
    }
    final raw = await preferences?.getString(_bodyKey);
    if (raw == null) {
      return null;
    }
    try {
      return _current ??= await _parse(raw);
    } on Object {
      // A saved copy that cannot be read (cut short, or of another shape)
      // is no saved copy: the relay's is asked for, whole.
      return null;
    }
  }

  Future<Result<CardCatalog>>? _refreshing;

  /// The shelf as the relay has it now. Asked once at a time: callers that
  /// ask while an answer is on its way share it.
  Future<Result<CardCatalog>> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<Result<CardCatalog>> _refresh() => Result.guard(() async {
    // Only a shelf this device holds can be answered "not modified".
    final cachedShelf = await cached();
    final etag = cachedShelf == null
        ? null
        : await preferences?.getString(_etagKey);
    final response = await api.getRaw(
      '/v1/customers/catalog',
      // This build asks for the account a top-up is sent to, so it is shown
      // those cards too.
      query: {'channel': channel, 'accounts': '1'},
      // Who is asking, when someone is signed in: the stores' review account
      // is shown the bundles even while none are on sale, so the feature
      // can be reviewed. Everyone else's shelf is the same as unsigned.
      withSession: true,
      headers: {
        'Accept': 'application/json',
        if (etag != null && cachedShelf != null) 'If-None-Match': etag,
      },
    );
    if (response.statusCode == 304 && cachedShelf != null) {
      return cachedShelf;
    }
    if (response.statusCode != 200) {
      throw RelayApiException(
        status: response.statusCode,
        code: 'catalog_unavailable',
      );
    }
    final shelf = await _parse(response.body);
    _current = shelf;
    try {
      // The tag goes first: a copy cut short between the two is then asked
      // for again, where a new tag over an old copy would keep the old one.
      await preferences?.remove(_etagKey);
      await preferences?.setString(_bodyKey, response.body);
      final newTag = response.headers['etag'];
      if (newTag != null) {
        await preferences?.setString(_etagKey, newTag);
      }
    } on Exception {
      // A full or failing disk costs the saved copy, not the shelf on screen.
    }
    return shelf;
  });

  /// A whole shelf is a couple of megabytes of JSON: read on the UI thread,
  /// it froze the first frames of a low-end phone. A small one (tests, a
  /// narrow channel) is read in place, where a second isolate costs more.
  static Future<CardCatalog> _parse(String raw) async {
    if (raw.length < _parseInBackgroundFrom) {
      return _parseNow(raw);
    }
    return compute(_parseNow, raw, debugLabel: 'catalog');
  }

  static const _parseInBackgroundFrom = 64 * 1024;

  static CardCatalog _parseNow(String raw) =>
      CardCatalog.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  /// The first part of the shelf: what the home screen shows first, a
  /// small answer that arrives long before the whole shelf on a slow line.
  /// For a first launch only; it is never saved as the device's copy, which
  /// must stay the whole shelf.
  Future<Result<CardCatalog>> firstPart() => Result.guard(() async {
    final response = await api.getRaw(
      '/v1/customers/catalog',
      query: {'channel': channel, 'accounts': '1', 'part': 'first'},
      headers: {'Accept': 'application/json'},
    );
    if (response.statusCode != 200) {
      throw RelayApiException(
        status: response.statusCode,
        code: 'catalog_unavailable',
      );
    }
    final part = await _parse(response.body);
    if (!part.partial) {
      // A relay from before parts answers with the whole shelf.
      _current ??= part;
    } else {
      _first = part;
    }
    return part;
  });

  CardCatalog? _first;

  /// The shelf brands and countries are looked up in: the whole one, or
  /// its first part while the whole one is on its way.
  CardCatalog? get _known => _current ?? _first;

  /// A brand of the shelf this device last saw.
  CardBrand? brandOf(String key) => _known?.brand(key);

  /// A bundle of the shelf this device last saw.
  ShelfBundle? shelfBundle(String key) => _known?.shelfBundle(key);

  /// The brand an order shows: its card's, or for a bundle the bundle with
  /// the cards actually bought (their network's artwork). A bundle no longer
  /// on the shelf still shows, under its order's name with its first card's
  /// art, so a bought one never loses its picture in «كروتي».
  CardBrand? brandOfOrder(CardOrder order) {
    final bundle = bundleOfBrandKey(order.brandKey);
    if (bundle.isEmpty) {
      return brandOf(order.brandKey);
    }
    // Its cards by their items; else (items this shelf no longer has) by
    // the brands its codes carry.
    final byItem = order.bundleItems.map(_brandOfItem).nonNulls.toList();
    final cards = byItem.isNotEmpty
        ? byItem
        : [for (final code in order.codes) ?brandOf(code.brandKey)];
    if (_known?.shelfBundle(bundle) case final shelf?) {
      final pick = [
        for (final part in shelf.tiers.first.parts)
          cards
                  .map((brand) => brand.key)
                  .where((key) => part.any((card) => card.brand.key == key))
                  .firstOrNull ??
              part.first.brand.key,
      ];
      return shelf.asBrand(pick);
    }
    return CardBrand(
      key: order.brandKey,
      name: order.name.split(' · ').first,
      aliases: const [],
      category: bundleCategory,
      rank: 0,
      featured: false,
      badge: '',
      redeemHint: '',
      logo: cards.firstOrNull?.logo ?? '',
      items: const [],
    );
  }

  CardBrand? _brandOfItem(String itemKey) => cardOfItem(itemKey)?.brand;

  /// A card on the shelf by its item key, with its brand.
  ({CardBrand brand, CardItem item})? cardOfItem(String itemKey) {
    for (final brand in _known?.brands ?? const <CardBrand>[]) {
      for (final item in brand.items) {
        if (item.key == itemKey) {
          return (brand: brand, item: item);
        }
      }
    }
    return null;
  }

  /// The countries by code of [_countriesOf], the shelf they were read from.
  Map<String, CardCountry> _countries = const {};
  CardCatalog? _countriesOf;

  CardCountry? _country(String code) {
    final shelf = _known;
    if (!identical(shelf, _countriesOf)) {
      _countriesOf = shelf;
      _countries = {
        // The first of a code wins, as the shelf lists it.
        for (final country
            in (shelf?.countries ?? const <CardCountry>[]).reversed)
          country.code: country,
      };
    }
    return _countries[code];
  }

  /// A country's name as the shelf calls it (its code when unknown).
  String countryName(String code) {
    final name = _country(code)?.name ?? '';
    return name.isEmpty ? code : name;
  }

  /// A country's flag reference, or empty.
  String countryFlag(String code) => _country(code)?.flag ?? '';

  /// Where a logo or flag reference is served.
  Uri imageUrl(String reference) {
    final sum = reference.startsWith('sha256:')
        ? reference.substring(7)
        : reference;
    return api.resolve('/v1/customers/images/$sum');
  }
}
