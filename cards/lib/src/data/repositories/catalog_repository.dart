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
      return _current ??= CardCatalog.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
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

  /// A brand of the shelf this device last saw.
  CardBrand? brandOf(String key) => _current?.brand(key);

  /// The countries by code of [_countriesOf], the shelf they were read from.
  Map<String, CardCountry> _countries = const {};
  CardCatalog? _countriesOf;

  CardCountry? _country(String code) {
    final shelf = _current;
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
