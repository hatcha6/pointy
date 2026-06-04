part of 'pos_view_model.dart';

extension PosBarcodeActions on PosViewModel {
  Future<bool> addVariantByBarcode(
    String barcode, {
    int quantity = 1,
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
          _addVariantToCartAndTrack(value, quantity: quantity, source: source);
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
    _notifyChanged();
  }
}
