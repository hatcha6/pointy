part of 'pos_view_model.dart';

extension PosBarcodeActions on PosViewModel {
  Future<bool> addProductByBarcode(String barcode, {int quantity = 1}) async {
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
          _addVariantToCart(value, quantity: quantity);
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
