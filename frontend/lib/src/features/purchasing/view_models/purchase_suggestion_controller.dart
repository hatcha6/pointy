import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/purchase_suggestion.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/services/local_scoped_json_storage.dart';

/// Owns the purchasing screen's suggestion strip: what to offer, when to ask
/// the server for it, and what the buyer has told us to stop offering.
///
/// Kept separate from [PurchaseViewModel] because its whole job is *not* being
/// in the way. Nothing here can block, slow or fail a draft edit: the fetch is
/// debounced and single-flighted, answers are cached per draft state so
/// undo/redo of a line costs nothing, the previous answer stays on screen while
/// a new one is in flight (a strip that blinks empty is worse than a stale one),
/// and every failure resolves to "show nothing".
class PurchaseSuggestionController extends ChangeNotifier {
  PurchaseSuggestionController({
    required PurchaseRepository repository,
    Duration debounce = const Duration(milliseconds: 200),
    ScopedJsonStorage muteStorage = const SharedPreferencesScopedJsonStorage(
      'pointy.purchase.suggestions.mutes.v1',
    ),
    this.muteScope = 'all',
  }) : _repository = repository,
       _debounce = debounce,
       _muteStorage = muteStorage {
    unawaited(_restoreMutes());
  }

  final PurchaseRepository _repository;
  final Duration _debounce;
  final ScopedJsonStorage _muteStorage;

  /// Which mute list this controller reads and writes. One list for the whole
  /// device is right for a real shop — "stop suggesting this" is about the
  /// shop's buying, not one buyer's — so the default is shared. A practice run
  /// passes its own scope instead; see [PurchaseViewModel].
  final String muteScope;

  /// Bounded so a long session cannot grow it without limit. 32 draft states is
  /// far more than the add/remove churn of one order.
  static const int _maxCachedStates = 32;

  final Map<String, PurchaseSuggestionSet> _cache = {};

  /// Products the buyer has explicitly told us not to suggest again, keyed
  /// `supplierId:variantId` — a mute is about this product *from this supplier*,
  /// which is the only scope in which the suggestion was ever made.
  final Set<String> _mutes = {};

  Timer? _debounceTimer;
  String? _pendingKey;
  String? _inFlightKey;
  bool _disposed = false;

  int? _supplierId;
  List<int> _variantIds = const [];

  PurchaseSuggestionSet _suggestions = PurchaseSuggestionSet.empty;
  bool _isRefreshing = false;
  bool _isCollapsed = false;

  /// Latched off once the shop's settings say the feature is disabled: the
  /// client stops asking entirely rather than polling for a "no" it already has.
  bool _featureEnabled = true;

  /// Suppliers whose history is genuinely empty. A supplier that has nothing to
  /// say with no lines on the draft has nothing to say with any, so one answer
  /// buys silence for the whole order instead of a request per line.
  final Set<int> _barrenSuppliers = {};

  /// Suggestions worth showing right now: never anything already on the draft,
  /// never anything muted.
  List<PurchaseSuggestion> get items {
    if (!isVisible) {
      return const [];
    }
    final onDraft = _variantIds.toSet();
    return [
      for (final item in _suggestions.items)
        if (!onDraft.contains(item.variantId) && !isMuted(item.variantId)) item,
    ];
  }

  /// The supplier's recurring order, minus whatever is already on the draft.
  PurchaseUsualBasket get usualBasket {
    if (!isVisible || !_suggestions.usualBasket.available) {
      return PurchaseUsualBasket.empty;
    }
    final onDraft = _variantIds.toSet();
    final remaining = [
      for (final item in _suggestions.usualBasket.items)
        if (!onDraft.contains(item.variantId)) item,
    ];
    return PurchaseUsualBasket(
      available: remaining.isNotEmpty,
      items: remaining,
    );
  }

  bool get isRefreshing => _isRefreshing;

  /// Whether the strip should be on screen at all. False collapses it to
  /// nothing — no empty state, no placeholder, no reserved band.
  bool get isVisible => _featureEnabled && !_isCollapsed && _supplierId != null;

  bool get hasAnything => items.isNotEmpty || usualBasket.available;

  bool get isCollapsed => _isCollapsed;

  bool isMuted(int variantId) => _mutes.contains(_muteKey(variantId));

  /// The habit for one draft line, when the server had a quantity to state for
  /// it. This is what the line tile's "usual 12" chip reads — the suggestion is
  /// already on the draft, so it is deliberately excluded from [items] and
  /// surfaced here instead.
  PurchaseSuggestion? quantityHintFor(int variantId) {
    if (!_featureEnabled) {
      return null;
    }
    for (final item in _suggestions.usualBasket.items) {
      if (item.variantId == variantId && item.hasQuantity) {
        return item;
      }
    }
    for (final item in _suggestions.items) {
      if (item.variantId == variantId && item.hasQuantity) {
        return item;
      }
    }
    return null;
  }

  /// Tell the controller what the buyer is looking at. Safe to call on every
  /// draft mutation — an unchanged state is a no-op and a cached one resolves
  /// without touching the network.
  void update({required int? supplierId, required List<int> variantIds}) {
    final normalized = List<int>.unmodifiable(variantIds);
    if (_supplierId == supplierId && listEquals(_variantIds, normalized)) {
      return;
    }
    final supplierChanged = _supplierId != supplierId;
    _supplierId = supplierId;
    _variantIds = normalized;

    if (supplierChanged) {
      // A different supplier is a different set of habits; nothing about the
      // old one applies, and the buyer gets the strip back if they had hidden it.
      _cache.clear();
      _suggestions = PurchaseSuggestionSet.empty;
      _isCollapsed = false;
    }

    if (supplierId == null ||
        !_featureEnabled ||
        _barrenSuppliers.contains(supplierId)) {
      _debounceTimer?.cancel();
      if (supplierChanged) {
        notifyListeners();
      }
      return;
    }

    final key = _stateKey(supplierId, normalized);
    final cached = _cache[key];
    if (cached != null) {
      _debounceTimer?.cancel();
      _pendingKey = null;
      _suggestions = cached;
      _isRefreshing = false;
      notifyListeners();
      return;
    }

    // The strip keeps showing the previous answer until the new one lands.
    _pendingKey = key;
    notifyListeners();
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, _fetchPending);
  }

  /// Hide the strip for the rest of this draft. Reappears for the next order —
  /// dismissing is "not now", not "never"; "never" is the shop setting.
  void collapse() {
    if (_isCollapsed) {
      return;
    }
    _isCollapsed = true;
    _debounceTimer?.cancel();
    notifyListeners();
  }

  /// Stop suggesting one product from this supplier, for good on this device.
  void mute(int variantId) {
    final key = _muteKey(variantId);
    if (!_mutes.add(key)) {
      return;
    }
    unawaited(_persistMutes());
    notifyListeners();
  }

  /// Forget the draft-scoped state (collapse, cached answers) when a new order
  /// starts. Mutes and the feature latch deliberately survive.
  void reset() {
    _debounceTimer?.cancel();
    _pendingKey = null;
    _cache.clear();
    _suggestions = PurchaseSuggestionSet.empty;
    _isCollapsed = false;
    _isRefreshing = false;
    _supplierId = null;
    _variantIds = const [];
    notifyListeners();
  }

  Future<void> _fetchPending() async {
    final key = _pendingKey;
    final supplierId = _supplierId;
    if (key == null || supplierId == null || _disposed) {
      return;
    }
    if (_inFlightKey == key) {
      return;
    }
    _inFlightKey = key;
    _isRefreshing = true;
    notifyListeners();

    final variantIds = _variantIds;
    final result = await _repository.loadPurchaseSuggestions(
      supplierId: supplierId,
      variantIds: variantIds,
    );
    if (_disposed) {
      return;
    }
    _inFlightKey = null;
    _isRefreshing = false;

    switch (result) {
      case Ok<PurchaseSuggestionSet>(:final value):
        if (!value.enabled) {
          // The shop turned suggestions off. Drop everything and never ask again.
          _featureEnabled = false;
          _suggestions = PurchaseSuggestionSet.empty;
          _cache.clear();
          notifyListeners();
          return;
        }
        if (variantIds.isEmpty && value.isEmpty) {
          _barrenSuppliers.add(supplierId);
        }
        _remember(key, value);
        // Only adopt the answer if the buyer has not moved on while it was in
        // flight; a stale answer would offer products for a draft that changed.
        if (key == _stateKey(_supplierId, _variantIds)) {
          _suggestions = value;
        }
      case Error<PurchaseSuggestionSet>():
        // Soft-fail: the strip is decoration and an offline backend must cost
        // the buyer nothing but a missing row of chips.
        break;
    }

    notifyListeners();

    // The draft moved on while this was in flight — chase the current state.
    final currentKey = _stateKey(_supplierId, _variantIds);
    if (_supplierId != null &&
        currentKey != key &&
        _cache[currentKey] == null) {
      _pendingKey = currentKey;
      _debounceTimer?.cancel();
      _debounceTimer = Timer(_debounce, _fetchPending);
    }
  }

  void _remember(String key, PurchaseSuggestionSet value) {
    _cache[key] = value;
    while (_cache.length > _maxCachedStates) {
      _cache.remove(_cache.keys.first);
    }
  }

  String _stateKey(int? supplierId, List<int> variantIds) {
    final sorted = [...variantIds]..sort();
    return '$supplierId:${sorted.join(",")}';
  }

  String _muteKey(int variantId) => '$_supplierId:$variantId';

  Future<void> _restoreMutes() async {
    try {
      final raw = await _muteStorage.load(muteScope);
      if (raw == null || _disposed) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return;
      }
      _mutes.addAll(decoded.whereType<String>());
      notifyListeners();
    } on Object {
      // A corrupted mute list is not worth a crash; the worst case is that a
      // suggestion the buyer hid comes back once.
    }
  }

  Future<void> _persistMutes() async {
    try {
      await _muteStorage.save(muteScope, jsonEncode(_mutes.toList()));
    } on Object {
      // Best-effort: mutes survive the session either way.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    super.dispose();
  }
}
