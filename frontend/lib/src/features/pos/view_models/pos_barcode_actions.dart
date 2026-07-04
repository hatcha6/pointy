part of 'pos_view_model.dart';

extension PosBarcodeActions on PosViewModel {
  Future<bool> addVariantByBarcode(
    String barcode, {
    double quantity = 1,
    String source = 'barcode_lookup',
  }) async {
    final normalizedBarcode = barcode.trim();
    if (normalizedBarcode.isEmpty ||
        quantity <= 0 ||
        _isCheckingOut ||
        isResolvingBarcode) {
      return false;
    }

    _lastScannedBarcode = normalizedBarcode;
    _lastScannedProductName = null;
    _barcodeScanStatus = BarcodeScanStatus.resolving;
    _notifyChanged();

    final result = await _catalogRepository.findProductVariantByBarcode(
      normalizedBarcode,
      activeOnly: true,
    );

    switch (result) {
      case Ok<ProductVariant?>(:final value):
        if (value == null) {
          _barcodeScanStatus = BarcodeScanStatus.notFound;
        } else {
          // Digital-scale labels carry the weight inside the barcode; for
          // metric products that weight IS the sold quantity.
          final scaleBarcode = parseScaleBarcode(normalizedBarcode);
          final resolvedQuantity = scaleBarcode != null && value.unit != 'piece'
              ? scaleBarcode.weightKg
              : quantity;
          _addVariantToCartAndTrack(
            value,
            quantity: resolvedQuantity,
            source: source,
          );
          // Arm the scan-then-type quick adjust on the line the scan landed on
          // (plain add: no modifiers, base unit — same merge key as the add).
          _lastScannedLineKey = _mergeableLineFor(value, const [], '')?.lineKey;
          _quickQuantityBuffer = '';
          _quickQuantityAt = null;
          _lastScannedProductName = value.displayLabel;
          _barcodeScanStatus = BarcodeScanStatus.found;
          unawaited(refreshDiscountPreview());
        }
      case Error<ProductVariant?>():
        _barcodeScanStatus = BarcodeScanStatus.error;
    }

    _notifyChanged();
    return _barcodeScanStatus == BarcodeScanStatus.found;
  }

  void clearBarcodeScanStatus() {
    if (_barcodeScanStatus == BarcodeScanStatus.idle) {
      return;
    }
    _barcodeScanStatus = BarcodeScanStatus.idle;
    _lastScannedBarcode = null;
    _lastScannedProductName = null;
    _lastScannedLineKey = null;
    _quickQuantityBuffer = '';
    _quickQuantityAt = null;
    _notifyChanged();
  }

  /// The cart line the last hardware scan landed on, if it is still in the
  /// cart — the target of the scan-then-type quantity/unit shortcuts.
  CartLine? get lastScannedCartLine {
    final lineKey = _lastScannedLineKey;
    if (lineKey == null) {
      return null;
    }
    return _cart.where((line) => line.lineKey == lineKey).firstOrNull;
  }

  /// Scan-then-type quantity: digits typed right after a scan REPLACE the last
  /// scanned line's quantity, accumulating across keystrokes ("1" then "2" →
  /// 12) until [_quickQuantityIdle] passes or another scan re-arms the flow.
  /// Returns false when there is nothing armed to adjust.
  bool applyQuickQuantityDigits(String digits) {
    if (_isCheckingOut || digits.isEmpty) {
      return false;
    }
    final line = lastScannedCartLine;
    if (line == null) {
      return false;
    }
    final now = DateTime.now();
    final startedAt = _quickQuantityAt;
    if (startedAt == null || now.difference(startedAt) > _quickQuantityIdle) {
      _quickQuantityBuffer = '';
    }
    final accumulated = _quickQuantityBuffer + digits;
    final quantity = int.tryParse(accumulated);
    if (quantity == null || accumulated.length > 4) {
      return false;
    }
    _quickQuantityBuffer = accumulated;
    _quickQuantityAt = now;
    if (quantity <= 0) {
      // A leading "0": keep accumulating ("05" → 5) without touching the line.
      return true;
    }
    setCartLineQuantity(
      line.lineKey,
      quantity.toDouble(),
      source: 'scan_quick_quantity',
    );
    return true;
  }

  /// Scan-then-arrow unit switch: replaces the last scanned line's unit with
  /// [unit] (resolved by the caller, which owns localisation of unit labels).
  bool applyQuickUnit(UnitOption unit) {
    if (_isCheckingOut) {
      return false;
    }
    final line = lastScannedCartLine;
    if (line == null) {
      return false;
    }
    setCartLineUnit(line.lineKey, unit);
    return true;
  }
}

const _quickQuantityIdle = Duration(seconds: 4);
