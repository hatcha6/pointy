import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../core/typed_lookup_text.dart';
import '../../../data/models/stock_unit.dart';

/// Asks the server about one identifier.
typedef UnitLookupFetch = Future<Result<StockUnitLookup>> Function(String code);

/// The products search's second question: *is this one article we hold or
/// sold?*
///
/// Somebody typing an IMEI, a VIN or a serial into the catalog is not looking
/// for the product — they want *that* handset, usually to answer «هل بعناه،
/// ولمن؟». So when the search text reads as an identifier, this asks the
/// unit lookup beside the product search, and the screen puts what it finds
/// above the product rows.
///
/// Built only for a shop that tracks articles and a reader who may see them —
/// see the catalog route — so a shop that sells soft drinks never asks.
///
/// Follows the search box: it is told every query the debounced field
/// reports, asks once per distinct identifier, and an answer to a query that
/// has since changed never lands — typing fast over a slow line must not
/// leave the previous handset's card above the next one's results.
class UnitSearchLookup extends ChangeNotifier {
  UnitSearchLookup(this._fetch);

  final UnitLookupFetch _fetch;

  /// The normalised identifier being answered; empty when the query is not
  /// one.
  String _code = '';
  int _token = 0;
  Future<StockUnitLookup?>? _inFlight;
  StockUnitLookup? _match;
  bool _disposed = false;

  /// A lookup is on its way for the current query.
  bool get isLoading => _inFlight != null;

  /// The current query as the server matches it — what tells the card that
  /// the second IMEI was the one typed.
  String get code => _code;

  /// What answered the current query — null when nothing did, or it is not an
  /// identifier, or the answer has not arrived.
  StockUnitLookup? get match => _match;

  /// The search text changed.
  void search(String text) => unawaited(_lookup(text));

  /// The answer for [text] — the one already known or on its way when [text]
  /// is the current query, otherwise a fresh ask that becomes the current
  /// query. What Enter and a scan wait on, so pressing Enter before the
  /// debounce fired does not ask twice.
  Future<StockUnitLookup?> resolve(String text) => _lookup(text);

  Future<StockUnitLookup?> _lookup(String text) {
    final code = looksLikeUnitIdentifier(text)
        ? normalizeUnitIdentifier(text)
        : '';
    if (code == _code) {
      return _inFlight ?? Future.value(_match);
    }
    final token = ++_token;
    _code = code;
    _match = null;
    if (code.isEmpty) {
      _inFlight = null;
      _notify();
      return Future.value(null);
    }
    final future = _ask(code, token);
    _inFlight = future;
    _notify();
    return future;
  }

  Future<StockUnitLookup?> _ask(String code, int token) async {
    final result = await _fetch(code);
    // A failed lookup is silence: the product results stand on their own,
    // and an error card for a question nobody asked out loud helps nobody.
    final answer = switch (result) {
      Ok<StockUnitLookup>(:final value) when value.hasMatch => value,
      _ => null,
    };
    if (token != _token || _disposed) {
      return answer;
    }
    _inFlight = null;
    _match = answer;
    _notify();
    return answer;
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
