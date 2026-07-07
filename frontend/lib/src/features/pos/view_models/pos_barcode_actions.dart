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

    final result = await _catalogRepository.resolveBarcode(
      normalizedBarcode,
      activeOnly: true,
    );

    switch (result) {
      case Ok<BarcodeResolution?>(:final value):
        if (value == null) {
          _barcodeScanStatus = BarcodeScanStatus.notFound;
        } else {
          final variant = value.variant;
          final matchedUnit = value.unit;
          // A packaging (unit) barcode — the carton EAN — rings up that unit:
          // one carton at the carton price, deducting its pieces from stock.
          final unitOption =
              matchedUnit != null && matchedUnit.isSellable
              ? UnitOption(
                  code: matchedUnit.code,
                  label: matchedUnit.label,
                  unitPrice: matchedUnit.resolvedPrice(variant.unitPrice),
                  factorToBase: matchedUnit.factorToBase,
                  allowsFractional: matchedUnit.allowsFractional,
                  isBase: false,
                )
              : null;
          // Digital-scale labels carry the weight inside the barcode; for
          // metric products that weight IS the sold quantity.
          final scaleBarcode = unitOption == null
              ? parseScaleBarcode(normalizedBarcode)
              : null;
          final resolvedQuantity =
              scaleBarcode != null && variant.unit != 'piece'
              ? scaleBarcode.weightKg
              : quantity;
          _addVariantToCartAndTrack(
            variant,
            quantity: resolvedQuantity,
            unit: unitOption,
            source: source,
          );
          // Arm the scan-then-type quick adjust on the line the scan landed on
          // (plain add: no modifiers, the scanned unit — same merge key as the
          // add).
          _lastScannedLineKey = _mergeableLineFor(
            variant,
            const [],
            _unitCodeFor(unitOption),
          )?.lineKey;
          _quickQuantityBuffer = '';
          _quickQuantityAt = null;
          _lastScannedProductName = unitOption == null
              ? variant.displayLabel
              : '${variant.displayLabel} — ${unitOption.label}';
          _barcodeScanStatus = BarcodeScanStatus.found;
          unawaited(refreshDiscountPreview());
        }
      case Error<BarcodeResolution?>():
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

  /// Scan-then-type quantity: keys typed right after a scan REPLACE the last
  /// scanned line's quantity, accumulating across keystrokes ("1" then "2" →
  /// 12; "2","." ,"5" → 2.5 for fractional units) until [_quickQuantityIdle]
  /// passes or another scan re-arms the flow. Returns false when there is
  /// nothing armed to adjust.
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
    if ('.'.allMatches(accumulated).length > 1) {
      // A second decimal point can't be honoured: drop the whole entry rather
      // than silently misreading it.
      _quickQuantityBuffer = '';
      return false;
    }
    final quantity = double.tryParse(accumulated);
    if (quantity == null && accumulated != '.' && !accumulated.endsWith('.')) {
      return false;
    }
    if (accumulated.length > 7) {
      return false;
    }
    _quickQuantityBuffer = accumulated;
    _quickQuantityAt = now;
    if (quantity == null || quantity <= 0) {
      // A leading "0" or a trailing "." — keep accumulating ("0.5", "2.5")
      // without touching the line yet.
      return true;
    }
    setCartLineQuantity(line.lineKey, quantity, source: 'scan_quick_quantity');
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
