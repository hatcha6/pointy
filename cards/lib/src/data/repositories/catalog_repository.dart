import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/result.dart';
import '../api/relay_api.dart';
import '../models/catalog.dart';

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
      return _current = CardCatalog.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } on FormatException {
      return null;
    }
  }

  /// The shelf as the relay has it now.
  Future<Result<CardCatalog>> refresh() => Result.guard(() async {
    // Only a shelf this device holds can be answered "not modified".
    final cachedShelf = await cached();
    final etag = cachedShelf == null
        ? null
        : await preferences?.getString(_etagKey);
    final response = await api.getRaw(
      '/v1/customers/catalog',
      query: {'channel': channel},
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
    final shelf = CardCatalog.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
    _current = shelf;
    await preferences?.setString(_bodyKey, response.body);
    final newTag = response.headers['etag'];
    if (newTag != null) {
      await preferences?.setString(_etagKey, newTag);
    }
    return shelf;
  });

  /// A brand of the shelf this device last saw.
  CardBrand? brandOf(String key) => _current?.brand(key);

  /// A country's name as the shelf calls it (its code when unknown).
  String countryName(String code) {
    for (final country in _current?.countries ?? const <CardCountry>[]) {
      if (country.code == code && country.name.isNotEmpty) {
        return country.name;
      }
    }
    return code;
  }

  /// A country's flag reference, or empty.
  String countryFlag(String code) {
    for (final country in _current?.countries ?? const <CardCountry>[]) {
      if (country.code == code) {
        return country.flag;
      }
    }
    return '';
  }

  /// Where a logo or flag reference is served.
  Uri imageUrl(String reference) {
    final sum = reference.startsWith('sha256:')
        ? reference.substring(7)
        : reference;
    return api.resolve('/v1/customers/images/$sum');
  }
}
