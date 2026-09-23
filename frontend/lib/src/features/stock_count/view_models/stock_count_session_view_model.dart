import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/product_unit.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/stock_count.dart';
import '../../../data/models/stock_count_draft.dart';
import '../../../data/models/stock_batch.dart';
import '../../../data/models/stock_count_line.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/stock_count_repository.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../data/services/local_scoped_json_storage.dart';
import 'stock_count_item_search_view_model.dart';

/// Pending "add to your count of N, or replace it?" decision for a re-scanned
/// item. Carries the just-entered quantity so the choice maps to the API mode.
class StockCountReentryPrompt {
  const StockCountReentryPrompt({
    required this.variant,
    required this.existingQuantity,
    required this.enteredQuantity,
  });

  final ProductVariant variant;
  final double existingQuantity;
  final double enteredQuantity;
}

/// State machine for the focused scan -> count -> next loop.
///
/// Blind invariant: this view model NEVER exposes the system/expected quantity
/// to the counting screen — not [currentVariant.quantityOnHand], and not a
/// saved line's expected quantity either. A variance is reviewed once, on the
/// reconciliation screen, where showing expected is the point. It used to be
/// asked here too, in a sheet raised after every save that crossed the
/// threshold, and that sheet broke the type-Enter-type-Enter loop this screen
/// is built around.
class StockCountSessionViewModel extends ChangeNotifier {
  StockCountSessionViewModel(
    this._repository,
    this._catalogRepository, {
    required StockCount session,
    TrackedStockRepository? trackedStockRepository,
    ScopedJsonStorage entryStorage = const SharedPreferencesScopedJsonStorage(
      'pointy.stockcount.entry.v1',
    ),
  }) : _session = session,
       _trackedStockRepository = trackedStockRepository,
       _entryStorage = entryStorage {
    _seedFromSession(session);
    unawaited(_restoreEntry());
    unawaited(search(''));
  }

  final StockCountRepository _repository;
  final CatalogRepository _catalogRepository;

  /// Only for the lot picker. Absent in the previews and in every test that
  /// counts anonymous stock, which is most of them.
  final TrackedStockRepository? _trackedStockRepository;
  final ScopedJsonStorage _entryStorage;

  final StockCount _session;

  // Local persistence of the un-submitted keypad entry. Counted lines already
  // persist server-side via recordLine; this only covers the in-flight item +
  // typed quantity. Keyed by the server session id.
  Timer? _persistDebounce;
  bool _entryRestored = false;

  // variantId -> the running counted quantity for already-counted lines.
  final Map<int, double> _countedByVariant = {};

  ProductVariant? _currentVariant;
  String _input = '';
  bool _isResolving = false;
  bool _isSaving = false;
  bool _scanMiss = false;
  bool _actionError = false;
  StockCountReentryPrompt? _pendingReentry;

  // -- scan-the-shelf (§6.6) ----------------------------------------------
  // For a serialized variant, counting a *number* is meaningless: two handsets
  // of one model are not interchangeable, and "4" is not an answer to which
  // four. So the keypad is replaced by a scan loop, and these hold what it has
  // read. Still blind: nothing here says whether a scan was expected.
  final List<StockCountScanResult> _scans = [];
  StockCountScanResult? _lastScan;
  String? _unknownCode;

  // -- counting one lot at a time (§6.6) ----------------------------------
  // A counter is standing in one room counting the packs of one lot on one
  // shelf, so the variance is against that lot's balance here and the lot's
  // stock elsewhere is neither shown nor touched.
  List<StockBatch> _lotsForCurrent = const [];
  int? _selectedLotId;
  bool _isLoadingLots = false;

  // -- counting in cartons (units of measure) -----------------------------
  // A shop whose goods arrive in cartons of 24 counts cartons. Blank means the
  // product's base unit, which is what every count was before and what a shop
  // that packs nothing will always send.
  String _countUnitCode = '';

  // -- the resting surface: search --------------------------------------
  // A count is a walk down a shelf, and the thing in hand is usually not the
  // thing with a readable barcode. The resting state of the counting screen is
  // therefore the search itself — not a button that opens one — because the
  // counter reaches for it between every pair of items and a dialog cost two
  // taps and a wait, every single time.
  late final StockCountItemSearchViewModel itemSearch =
      StockCountItemSearchViewModel(_catalogRepository)
        ..addListener(notifyListeners);

  StockCount get session => _session;
  ProductVariant? get currentVariant => _currentVariant;
  String get input => _input;
  bool get isResolving => _isResolving;
  bool get isSaving => _isSaving;
  bool get scanMiss => _scanMiss;
  bool get actionError => _actionError;
  StockCountReentryPrompt? get pendingReentry => _pendingReentry;

  /// Identifiers read in this session, newest first.
  List<StockCountScanResult> get scans => List.unmodifiable(_scans);
  StockCountScanResult? get lastScan => _lastScan;

  /// A code that resolved to nothing at all. There is no way to know what
  /// product it is, so the counter is asked — which is §6.6's
  /// *opening-identification proposal* made actionable instead of a line in a
  /// report nobody reads.
  String? get unknownCode => _unknownCode;

  /// Whether the item in hand is counted by scanning rather than by typing.
  bool get countsByScan => _currentVariant?.trackingMode.tracksUnits ?? false;

  /// Whether the item in hand is counted one lot at a time.
  bool get countsByLot {
    final mode = _currentVariant?.trackingMode;
    return mode != null && mode.tracksLots && !mode.tracksUnits;
  }

  List<StockBatch> get lotsForCurrent => _lotsForCurrent;
  int? get selectedLotId => _selectedLotId;
  bool get isLoadingLots => _isLoadingLots;

  /// Units the item in hand can be counted in: its base unit first, then every
  /// pack the product is defined in.
  ///
  /// Purchase-only packs are included on purpose. Counting is not selling — a
  /// carton the shop only ever buys in is still a carton standing on a shelf,
  /// and the server resolves it the same way.
  List<ProductUnit> get countUnitsForCurrent =>
      _currentVariant?.productDetail?.units ?? const [];

  /// The unit the typed number is in. Blank = the product's base unit.
  String get countUnitCode => _countUnitCode;

  void selectCountUnit(String code) {
    if (_countUnitCode == code) {
      return;
    }
    _countUnitCode = code;
    notifyListeners();
  }

  String get searchTerm => itemSearch.term;
  List<ProductVariant> get searchResults => itemSearch.results;
  bool get isSearching => itemSearch.isLoading;
  bool get searchError => itemSearch.hasError;
  bool get searchHasMore => itemSearch.hasMore;

  /// What THIS counter has already entered for a variant, or null when they
  /// have not counted it yet.
  ///
  /// Blind-safe: it is the counter's own number coming back to them, never the
  /// system's. Showing it on the search list is what lets someone walking a
  /// shelf of 20,000 lines see what they have already done — and skip an item
  /// they do not want to count right now.
  double? countedQuantityFor(int variantId) => _countedByVariant[variantId];

  void selectLot(int? lotId) {
    _selectedLotId = lotId;
    _input = '';
    notifyListeners();
  }

  /// How many of the current variant have been scanned so far. The counter
  /// needs to see their own progress; they are not being told what to expect.
  int get scannedForCurrent {
    final variant = _currentVariant;
    if (variant == null) {
      return 0;
    }
    return _scans.where((scan) => scan.variantId == variant.id).length;
  }

  int get countedCount => _countedByVariant.length;
  int get expectedCount => _session.expectedLineCount;
  double get progress {
    if (expectedCount <= 0) {
      return countedCount > 0 ? 1 : 0;
    }
    return (countedCount / expectedCount).clamp(0, 1).toDouble();
  }

  /// Whether the typed count is a number at all. Separate from [canSubmit]
  /// (which also covers the lot picker and an in-flight save) so pressing
  /// Enter on "1.2.3" says why instead of doing nothing.
  bool get hasValidInput => _parsedInput() != null;

  bool get canSubmit =>
      _currentVariant != null &&
      _parsedInput() != null &&
      !_isSaving &&
      // A lot-tracked line that did not say which lot is a variance against a
      // total the counter never looked at, and the backend refuses it.
      (!countsByLot || _selectedLotId != null);

  void _seedFromSession(StockCount session) {
    _countedByVariant.clear();
    for (final line in session.lines) {
      _countedByVariant[line.variantId] = line.countedQuantity;
    }
  }

  String get _entryScope => '${_session.id}';

  @override
  void notifyListeners() {
    super.notifyListeners();
    _scheduleEntryPersist();
  }

  @override
  void dispose() {
    _persistDebounce?.cancel();
    itemSearch
      ..removeListener(notifyListeners)
      ..dispose();
    super.dispose();
  }

  void _scheduleEntryPersist() {
    // Skip until the prior entry has been restored, so we never clobber it.
    if (!_entryRestored) {
      return;
    }
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(_flushEntry());
    });
  }

  Future<void> _flushEntry() async {
    try {
      final variant = _currentVariant;
      if (variant == null || _input.isEmpty) {
        await _entryStorage.clear(_entryScope);
        return;
      }
      await _entryStorage.save(
        _entryScope,
        jsonEncode({
          'variant': variant.toCartJson(),
          'input': _input,
          // Without this a restored "3" means three pieces, not three cartons.
          'unit': _countUnitCode,
        }),
      );
    } catch (_) {
      // Best-effort — storage may be unavailable (e.g. in tests).
    }
  }

  /// Restores an un-submitted keypad entry (current item + typed quantity) so a
  /// crash mid-count doesn't lose the in-progress entry. Confirmed counts come
  /// back from the server via [_seedFromSession].
  Future<void> _restoreEntry() async {
    String? raw;
    try {
      raw = await _entryStorage.load(_entryScope);
    } catch (_) {
      raw = null;
    }
    _entryRestored = true;
    if (raw == null || raw.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }
      final map = decoded.cast<String, Object?>();
      final variantJson = map['variant'];
      final input = map['input']?.toString() ?? '';
      // Don't clobber a selection the user made during the async load.
      if (variantJson is! Map || input.isEmpty || _currentVariant != null) {
        return;
      }
      _currentVariant = ProductVariant.fromJson(
        variantJson.cast<String, Object?>(),
      );
      _input = input;
      _countUnitCode = map['unit']?.toString() ?? '';
      notifyListeners();
    } on FormatException {
      // Corrupt entry — ignore.
    }
  }

  // -- search ---------------------------------------------------------------

  Future<void> search(String term) => itemSearch.search(term);
  Future<void> loadMoreSearchResults() => itemSearch.loadMore();
  Future<void> retrySearch() => itemSearch.retry();

  /// The Enter key's half of the fast loop: type a name (or a code), press
  /// Enter, and the best match is in hand with the quantity field waiting.
  /// Returns false when nothing matched, so the screen can say so instead of
  /// silently doing nothing.
  Future<bool> selectTopSearchMatch(String term) async {
    final match = await itemSearch.resolveTopMatch(term);
    if (match == null) {
      return false;
    }
    selectVariant(match);
    return true;
  }

  // -- scanning / selection ------------------------------------------------

  Future<void> onBarcodeScanned(String barcode) async {
    if (barcode.trim().isEmpty || _isResolving) {
      return;
    }
    _isResolving = true;
    _scanMiss = false;
    notifyListeners();

    final result = await _catalogRepository.findProductVariantByBarcode(
      barcode,
    );
    if (result is Ok<ProductVariant?> && result.value != null) {
      _isResolving = false;
      selectVariant(result.value!);
      return;
    }
    // Not a product barcode. On a shelf of identified goods the next most
    // likely thing it is, is an article's own number — which is the same
    // "one scan, one answer, on the miss path" rule the till follows.
    await _recordIdentifier(barcode);
    _isResolving = false;
    notifyListeners();
  }

  /// Read one article's identifier into the count.
  ///
  /// Called both from the scanner (on the miss path above) and from the
  /// scan-the-shelf surface, where every scan is an identifier by definition.
  Future<void> recordIdentifier(String code) async {
    if (code.trim().isEmpty || _isResolving) {
      return;
    }
    _isResolving = true;
    notifyListeners();
    await _recordIdentifier(code);
    _isResolving = false;
    notifyListeners();
  }

  Future<void> _recordIdentifier(String code, {int? variantId}) async {
    final scanned = await _repository.scan(
      _session.id,
      code.trim(),
      variantId: variantId,
    );
    switch (scanned) {
      case Ok<StockCountScanResult>():
        final scan = scanned.value;
        _lastScan = scan;
        _scanMiss = false;
        if (scan.created) {
          _scans.insert(0, scan);
        }
        if (!scan.known && scan.variantId == null) {
          // Nothing in the shop has ever answered to this. Ask what it is
          // rather than dropping it: it is either goods that were never
          // received or goods that came back and were never restocked, and
          // both are findings.
          _unknownCode = scan.code;
        } else if (scan.variantId != null && _currentVariant == null) {
          _countedByVariant[scan.variantId!] = 0;
        }
      case Error<StockCountScanResult>():
        _scanMiss = true;
    }
  }

  /// Attach the unrecognised code the counter has just identified.
  Future<void> attachUnknownScan(ProductVariant variant) async {
    final code = _unknownCode;
    if (code == null) {
      return;
    }
    _unknownCode = null;
    _isSaving = true;
    notifyListeners();
    await _recordIdentifier(code, variantId: variant.id);
    _isSaving = false;
    notifyListeners();
  }

  void dismissUnknownScan() {
    _unknownCode = null;
    notifyListeners();
  }

  void selectVariant(ProductVariant variant) {
    _currentVariant = variant;
    _input = '';
    _scanMiss = false;
    _selectedLotId = null;
    _lotsForCurrent = const [];
    // A unit belongs to the item in hand, never to the session: the next thing
    // off the shelf is not necessarily packed the same way.
    _countUnitCode = '';
    notifyListeners();
    if (countsByLot) {
      unawaited(_loadLots(variant));
    }
  }

  Future<void> _loadLots(ProductVariant variant) async {
    _isLoadingLots = true;
    notifyListeners();
    final result = await _trackedStockRepository?.loadSellableBatches(
      variantId: variant.id,
    );
    _isLoadingLots = false;
    if (result is Ok<StockBatchPage> && _currentVariant?.id == variant.id) {
      _lotsForCurrent = result.value.batches;
      if (_lotsForCurrent.length == 1) {
        _selectedLotId = _lotsForCurrent.first.id;
      }
    }
    notifyListeners();
  }

  void clearCurrent() {
    _currentVariant = null;
    _input = '';
    _selectedLotId = null;
    _lotsForCurrent = const [];
    _countUnitCode = '';
    notifyListeners();
  }

  // -- keypad --------------------------------------------------------------

  /// Sets the count from a real text field.
  ///
  /// The on-screen keypad is the phone path; a till has a keyboard and a
  /// counter who can type faster than they can tap. Both write the same
  /// string, so whichever is in use the other stays in step.
  void setInput(String value) {
    // Keep only what a quantity can be. A wedge burst that lands here while
    // the field has focus is undone by BarcodeScanListener a moment later; the
    // filter means what it leaves behind in the meantime is at least a number.
    final cleaned = value.replaceAll(RegExp(r'[^0-9.]'), '');
    if (cleaned == _input) {
      return;
    }
    _input = cleaned;
    notifyListeners();
  }

  void appendDigit(String digit) {
    _input = '$_input$digit';
    notifyListeners();
  }

  void appendDecimal() {
    if (_input.contains('.')) {
      return;
    }
    _input = _input.isEmpty ? '0.' : '$_input.';
    notifyListeners();
  }

  void backspace() {
    if (_input.isEmpty) {
      return;
    }
    _input = _input.substring(0, _input.length - 1);
    notifyListeners();
  }

  void clearInput() {
    _input = '';
    notifyListeners();
  }

  // -- saving --------------------------------------------------------------

  /// Submits the entered count. If the item was already counted, raises the
  /// add/replace prompt instead of saving immediately.
  Future<void> submit() async {
    final variant = _currentVariant;
    final quantity = _parsedInput();
    if (variant == null || quantity == null) {
      return;
    }
    if (_countedByVariant.containsKey(variant.id)) {
      _pendingReentry = StockCountReentryPrompt(
        variant: variant,
        existingQuantity: _countedByVariant[variant.id]!,
        enteredQuantity: quantity,
      );
      notifyListeners();
      return;
    }
    await _record(variant, quantity, StockCountEntryMode.replace);
  }

  Future<void> resolveReentry(StockCountEntryMode mode) async {
    final prompt = _pendingReentry;
    if (prompt == null) {
      return;
    }
    _pendingReentry = null;
    await _record(prompt.variant, prompt.enteredQuantity, mode);
  }

  void cancelReentry() {
    _pendingReentry = null;
    notifyListeners();
  }

  Future<void> _record(
    ProductVariant variant,
    double quantity,
    StockCountEntryMode mode,
  ) async {
    _isSaving = true;
    _actionError = false;
    notifyListeners();

    final result = await _repository.recordLine(
      _session.id,
      StockCountLineDraft(
        variantId: variant.id,
        countedQuantity: quantity,
        mode: mode,
        batchId: countsByLot ? _selectedLotId : null,
        unitCode: _countUnitCode,
      ),
    );

    _isSaving = false;
    switch (result) {
      case Ok<StockCountLine>():
        final line = result.value;
        _countedByVariant[variant.id] = line.countedQuantity;
        _currentVariant = null;
        _input = '';
        _selectedLotId = null;
        _lotsForCurrent = const [];
        _countUnitCode = '';
        // This item is done: the next one starts from an empty field, not from
        // the word that found this one. (Backing out of an item deliberately
        // does NOT reset it — there the counter is still looking at the list
        // they just picked the wrong row from.)
        unawaited(itemSearch.reset());
      case Error<StockCountLine>():
        _actionError = true;
    }
    notifyListeners();
  }

  void acknowledgeScanMiss() {
    _scanMiss = false;
    notifyListeners();
  }

  void acknowledgeActionError() {
    _actionError = false;
    notifyListeners();
  }

  double? _parsedInput() {
    final trimmed = _input.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final value = double.tryParse(trimmed);
    if (value == null || value < 0) {
      return null;
    }
    return value;
  }
}
