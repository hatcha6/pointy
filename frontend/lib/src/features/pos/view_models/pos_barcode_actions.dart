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
    // A hardware scan's key burst lands in the (focused) search field and queues
    // a debounced search; clear the field and cancel that debounce now so the
    // barcode can't reappear in the field a moment later. Only for the wedge
    // path — the manual "type a term and press Enter" path must keep the typed
    // search (it clears itself via onSubmitted only when it resolves).
    if (source == 'hardware_scanner') {
      _searchResetController.requestReset();
    }
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
          final unitOption = matchedUnit != null && matchedUnit.isSellable
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
          // Track the line the scan landed on as the active line for the
          // F2 (cycle unit) / F4 (delete) / arrow (cycle unit) shortcuts — a
          // plain add (no modifiers, the scanned unit) shares the add's merge
          // key. The scan changes only its own line's quantity, never another's.
          _activeCartLineKey = _mergeableLineFor(
            variant,
            const [],
            _unitCodeFor(unitOption),
          )?.lineKey;
          _lastScannedProductName = unitOption == null
              ? variant.displayLabel
              : '${variant.displayLabel} — ${unitOption.label}';
          _barcodeScanStatus = BarcodeScanStatus.found;
          unawaited(refreshDiscountPreview());
        }
      case Error<BarcodeResolution?>():
        _barcodeScanStatus = BarcodeScanStatus.error;
    }

    // One chime per scan outcome, mirroring the status line the cashier sees.
    _scanFeedback?.call(switch (_barcodeScanStatus) {
      BarcodeScanStatus.found => ScanFeedback.success,
      BarcodeScanStatus.notFound => ScanFeedback.notFound,
      _ => ScanFeedback.error,
    });

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
    _notifyChanged();
  }

  /// The cart line the shortcuts act on: the last line a scan or catalog tap
  /// landed on, or the last line the cashier tapped to select — whichever came
  /// most recently — provided it is still in the cart. Target of F2 (cycle
  /// unit), F4 (delete), and the arrow-key unit cycle.
  CartLine? get activeCartLine {
    final lineKey = _activeCartLineKey;
    if (lineKey == null) {
      return null;
    }
    return _cart.where((line) => line.lineKey == lineKey).firstOrNull;
  }

  /// Marks the tapped cart line as the active one so the keyboard shortcuts
  /// (F2 / F4 / arrows) target it. No rebuild is needed — the shortcuts read
  /// [activeCartLine] on demand — so this intentionally does not notify.
  void focusCartLine(String lineKey) {
    _activeCartLineKey = lineKey;
  }

  /// Switches the active cart line's unit of measure to [unit] (resolved by the
  /// caller, which owns localisation of unit labels). Backs the F2 and arrow-key
  /// cycle. Returns false when there is no active line.
  bool setActiveCartLineUnit(UnitOption unit) {
    if (_isCheckingOut) {
      return false;
    }
    final line = activeCartLine;
    if (line == null) {
      return false;
    }
    setCartLineUnit(line.lineKey, unit);
    return true;
  }
}
