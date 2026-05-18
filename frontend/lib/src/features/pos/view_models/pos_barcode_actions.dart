part of 'pos_view_model.dart';

extension PosBarcodeActions on PosViewModel {
  Future<void> addProductByBarcode(String barcode) async {
    final normalizedBarcode = barcode.trim();
    if (normalizedBarcode.isEmpty || _isCheckingOut || isResolvingBarcode) {
      return;
    }

    _lastScannedBarcode = normalizedBarcode;
    _lastScannedProductName = null;
    _barcodeScanStatus = BarcodeScanStatus.resolving;
    _notifyChanged();

    final result = await _catalogRepository.findProductByBarcode(
      normalizedBarcode,
      activeOnly: true,
    );

    switch (result) {
      case Ok<Product?>(:final value):
        if (value == null) {
          _barcodeScanStatus = BarcodeScanStatus.notFound;
        } else {
          _addProductToCart(value);
          _lastScannedProductName = value.name;
          _barcodeScanStatus = BarcodeScanStatus.found;
        }
      case Error<Product?>():
        _barcodeScanStatus = BarcodeScanStatus.error;
    }

    _notifyChanged();
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
