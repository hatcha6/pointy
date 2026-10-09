import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/voucher_pricing.dart';
import '../../../data/repositories/integrations_repository.dart';
import '../../../data/services/api_session.dart';

/// The Arabic message the server put on a refused price (400 with
/// `{"price": "…"}`), or null when it said none.
String? pricingErrorMessage(Object error) {
  if (error is! PosApiException) {
    return null;
  }
  try {
    final decoded = jsonDecode(error.responseBody);
    if (decoded is Map) {
      for (final key in const [
        'price',
        'mode',
        'markup_percent',
        'detail',
        'error',
      ]) {
        final value = decoded[key];
        if (value is String && value.trim().isNotEmpty) {
          return value;
        }
        if (value is List && value.isNotEmpty && value.first is String) {
          return value.first as String;
        }
      }
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// What a shop's own price would be: the shop pays plus [markupPercent],
/// rounded up to a quarter dinar like the company's suggestion.
double? markupExample(double? shopPays, double? markupPercent) {
  if (shopPays == null || markupPercent == null) {
    return null;
  }
  final raw = shopPays * (1 + markupPercent / 100);
  return (raw / 0.25).ceil() * 0.25;
}

/// «أسعار كروت دفتر»: the services tab (mode, markup) and the cards tab
/// (search, brand, per-row price, bulk follow-company).
class VoucherPricingViewModel extends ChangeNotifier {
  VoucherPricingViewModel(this._repository);

  final IntegrationsRepository _repository;
  bool _disposed = false;

  // --- services ---------------------------------------------------------
  VoucherPricing? _pricing;
  bool _loading = false;
  bool _loadFailed = false;
  bool _forbidden = false;
  bool _saving = false;
  bool _dirty = false;
  String? _saveError;
  bool _saved = false;

  VoucherPricing? get pricing => _pricing;
  bool get isLoading => _loading;
  bool get loadFailed => _loadFailed;
  bool get isForbidden => _forbidden;
  bool get isSaving => _saving;
  bool get isDirty => _dirty;
  bool get justSaved => _saved;

  /// The server's own message for a refused save, when it gave one.
  String? get saveError => _saveError;
  bool get saveFailed => _saveError != null;

  Future<void> loadPricing() async {
    _loading = true;
    _loadFailed = false;
    _notify();
    final result = await _repository.loadVoucherPricing();
    _loading = false;
    switch (result) {
      case Ok(:final value):
        _pricing = value;
        _dirty = false;
      case Error(:final exception):
        _loadFailed = true;
        _forbidden =
            exception is PosApiException && exception.statusCode == 403;
    }
    _notify();
  }

  void setDefaultMode(PricingMode mode) => _edit(
    (p) => p.copyWith(
      defaultMode: mode,
      defaultMarkupPercent: mode == PricingMode.custom
          ? (p.defaultMarkupPercent ?? 5)
          : null,
    ),
  );

  void setDefaultMarkup(double? percent) =>
      _edit((p) => p.copyWith(defaultMarkupPercent: percent));

  void setServiceMode(PricingService service, PricingMode mode) => _editService(
    service,
    (s) => s.copyWith(
      mode: mode,
      markupPercent: mode == PricingMode.custom
          ? (s.markupPercent ?? _pricing?.defaultMarkupPercent ?? 5)
          : null,
    ),
  );

  void setServiceMarkup(PricingService service, double? percent) =>
      _editService(service, (s) => s.copyWith(markupPercent: percent));

  void _editService(
    PricingService service,
    PricingService Function(PricingService) change,
  ) => _edit(
    (p) => p.copyWith(
      services: [
        for (final s in p.services)
          if (s.key == service.key && s.country == service.country)
            change(s)
          else
            s,
      ],
    ),
  );

  void _edit(VoucherPricing Function(VoucherPricing) change) {
    final current = _pricing;
    if (current == null) {
      return;
    }
    _pricing = change(current);
    _dirty = true;
    _saved = false;
    _saveError = null;
    _notify();
  }

  Future<bool> savePricing() async {
    final current = _pricing;
    if (current == null || _saving) {
      return false;
    }
    _saving = true;
    _saveError = null;
    _notify();
    final result = await _repository.saveVoucherPricing(current);
    _saving = false;
    var ok = false;
    switch (result) {
      case Ok(:final value):
        _pricing = value;
        _dirty = false;
        _saved = true;
        ok = true;
      case Error(:final exception):
        _saveError = pricingErrorMessage(exception) ?? '';
    }
    _notify();
    return ok;
  }

  // --- cards ------------------------------------------------------------
  final List<CardPriceRow> _rows = [];
  final Set<String> _brands = {};
  String _search = '';
  String _brand = '';
  int _page = 0;
  bool _cardsLoading = false;
  bool _cardsFailed = false;
  bool _hasMore = false;
  int _count = 0;
  int _cardsToken = 0;
  String? _cardError;
  int? _savingVariant;
  bool _bulkBusy = false;
  bool _belowCostOnly = false;
  int _belowCostCount = 0;

  /// Only the cards blocked for being priced under cost.
  bool get belowCostOnly => _belowCostOnly;

  /// Every such card of the shop, whatever the filter and the page.
  int get belowCostCount => _belowCostCount;

  List<CardPriceRow> get rows => List.unmodifiable(_rows);
  List<String> get brands => (_brands.toList()..sort());
  String get search => _search;
  String get brand => _brand;
  bool get cardsLoading => _cardsLoading;
  bool get cardsFailed => _cardsFailed;
  bool get hasMore => _hasMore;
  int get count => _count;
  String? get cardError => _cardError;
  int? get savingVariant => _savingVariant;
  bool get isBulkBusy => _bulkBusy;

  Future<void> loadCards({
    String? search,
    String? brand,
    bool? belowCostOnly,
  }) async {
    _search = search ?? _search;
    _brand = brand ?? _brand;
    _belowCostOnly = belowCostOnly ?? _belowCostOnly;
    _page = 0;
    _rows.clear();
    _hasMore = false;
    await _loadPage();
  }

  /// A failed page keeps [hasMore]: the cashier can retry the same page.
  Future<void> loadMore() async {
    if (_cardsLoading || !_hasMore) {
      return;
    }
    await _loadPage();
  }

  Future<void> _loadPage() async {
    final token = ++_cardsToken;
    _cardsLoading = true;
    _cardsFailed = false;
    _notify();
    final result = await _repository.loadVoucherCardPrices(
      search: _search,
      brand: _brand,
      page: _page + 1,
      belowCost: _belowCostOnly,
    );
    if (token != _cardsToken) {
      return;
    }
    _cardsLoading = false;
    switch (result) {
      case Ok(:final value):
        _page = value.page;
        _rows.addAll(value.rows);
        _count = value.count;
        _hasMore = value.hasMore;
        _belowCostCount = value.belowCostCount;
        if (_brand.isEmpty) {
          _brands.addAll(
            value.rows.map((r) => r.brand).where((b) => b.isNotEmpty),
          );
        }
      case Error():
        _cardsFailed = true;
        if (_page == 0) {
          _hasMore = false;
        }
    }
    _notify();
  }

  /// Sets one card's own price, or hands it back to the company when [price]
  /// is null. Resolves true when saved; [cardError] says why not.
  Future<bool> saveCardPrice(CardPriceRow row, double? price) async {
    _cardError = null;
    _savingVariant = row.variantId;
    _notify();
    final result = await _repository.saveVoucherCardPrice(
      row.variantId,
      mode: price == null ? PricingMode.company : PricingMode.custom,
      price: price,
    );
    _savingVariant = null;
    var ok = false;
    switch (result) {
      case Ok(:final value):
        final i = _rows.indexWhere((r) => r.variantId == row.variantId);
        if (i >= 0) {
          _rows[i] = value;
        }
        ok = true;
      case Error(:final exception):
        _cardError = pricingErrorMessage(exception) ?? '';
    }
    _notify();
    return ok;
  }

  /// Hands every listed card (or the whole brand filter) back to the company.
  Future<bool> followCompany() async {
    _cardError = null;
    _bulkBusy = true;
    _notify();
    final result = await _repository.bulkVoucherCardPrices(
      variantIds: _brand.isEmpty ? [for (final r in _rows) r.variantId] : null,
      brand: _brand.isEmpty ? null : _brand,
      mode: PricingMode.company,
    );
    _bulkBusy = false;
    final ok = result is Ok<int>;
    if (result case Error(:final exception)) {
      _cardError = pricingErrorMessage(exception) ?? '';
    }
    _notify();
    if (ok) {
      await loadCards();
    }
    return ok;
  }

  /// «استخدام تسعير الشركة» for every card whose own price fell under cost.
  Future<bool> followCompanyForBelowCost() async {
    _cardError = null;
    _bulkBusy = true;
    _notify();
    final result = await _repository.bulkVoucherCardPrices(
      mode: PricingMode.company,
      belowCost: true,
    );
    _bulkBusy = false;
    final ok = result is Ok<int>;
    if (result case Error(:final exception)) {
      _cardError = pricingErrorMessage(exception) ?? '';
    }
    _notify();
    if (ok) {
      await loadCards(belowCostOnly: false);
    }
    return ok;
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
