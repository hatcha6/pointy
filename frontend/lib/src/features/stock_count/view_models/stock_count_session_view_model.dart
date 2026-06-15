import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/stock_count.dart';
import '../../../data/models/stock_count_draft.dart';
import '../../../data/models/stock_count_line.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/stock_count_repository.dart';

/// The one quiet variance question, surfaced once after an entry crosses the
/// threshold. Holding [expected] here is the ONLY place the system quantity is
/// exposed to the counting flow (see the blind invariant note below).
class StockCountVariancePrompt {
  const StockCountVariancePrompt({
    required this.variant,
    required this.expected,
    required this.counted,
  });

  final ProductVariant variant;
  final double expected;
  final double counted;
}

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
/// to the counting screen. [currentVariant.quantityOnHand] is deliberately
/// ignored, and a line's expected quantity is only ever read into
/// [pendingVariance] to build the single variance prompt. Reconciliation is a
/// separate screen where showing expected is intended.
class StockCountSessionViewModel extends ChangeNotifier {
  StockCountSessionViewModel(
    this._repository,
    this._catalogRepository, {
    required StockCount session,
  }) : _session = session {
    _seedFromSession(session);
  }

  final StockCountRepository _repository;
  final CatalogRepository _catalogRepository;

  final StockCount _session;

  // variantId -> the running counted quantity for already-counted lines.
  final Map<int, double> _countedByVariant = {};

  ProductVariant? _currentVariant;
  String _input = '';
  bool _isResolving = false;
  bool _isSaving = false;
  bool _scanMiss = false;
  bool _actionError = false;
  StockCountVariancePrompt? _pendingVariance;
  StockCountReentryPrompt? _pendingReentry;

  StockCount get session => _session;
  ProductVariant? get currentVariant => _currentVariant;
  String get input => _input;
  bool get isResolving => _isResolving;
  bool get isSaving => _isSaving;
  bool get scanMiss => _scanMiss;
  bool get actionError => _actionError;
  StockCountVariancePrompt? get pendingVariance => _pendingVariance;
  StockCountReentryPrompt? get pendingReentry => _pendingReentry;

  int get countedCount => _countedByVariant.length;
  int get expectedCount => _session.expectedLineCount;
  double get progress {
    if (expectedCount <= 0) {
      return countedCount > 0 ? 1 : 0;
    }
    return (countedCount / expectedCount).clamp(0, 1).toDouble();
  }

  bool get canSubmit =>
      _currentVariant != null && _parsedInput() != null && !_isSaving;

  void _seedFromSession(StockCount session) {
    _countedByVariant.clear();
    for (final line in session.lines) {
      _countedByVariant[line.variantId] = line.countedQuantity;
    }
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
    _isResolving = false;
    if (result is Ok<ProductVariant?> && result.value != null) {
      selectVariant(result.value!);
      return;
    }
    _scanMiss = true;
    notifyListeners();
  }

  void selectVariant(ProductVariant variant) {
    _currentVariant = variant;
    _input = '';
    _scanMiss = false;
    notifyListeners();
  }

  void clearCurrent() {
    _currentVariant = null;
    _input = '';
    notifyListeners();
  }

  // -- keypad --------------------------------------------------------------

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
      ),
    );

    _isSaving = false;
    switch (result) {
      case Ok<StockCountLine>():
        final line = result.value;
        _countedByVariant[variant.id] = line.countedQuantity;
        _currentVariant = null;
        _input = '';
        if (line.needsReview) {
          // Blind invariant: expected is read into the prompt only — never shown
          // on the counting surface itself.
          _pendingVariance = StockCountVariancePrompt(
            variant: variant,
            expected: line.expectedQuantity,
            counted: line.countedQuantity,
          );
        }
      case Error<StockCountLine>():
        _actionError = true;
    }
    notifyListeners();
  }

  void confirmVariance() {
    _pendingVariance = null;
    notifyListeners();
  }

  void recountVariance() {
    final prompt = _pendingVariance;
    _pendingVariance = null;
    if (prompt != null) {
      _currentVariant = prompt.variant;
      _input = '';
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
