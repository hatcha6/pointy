part of 'pos_view_model.dart';

extension PosCartActions on PosViewModel {
  void addVariant(ProductVariant variant, {int quantity = 1}) {
    if (_addVariantToCart(variant, quantity: quantity)) {
      _notifyChanged();
      unawaited(refreshDiscountPreview());
    }
  }

  void decrementVariant(ProductVariant variant) {
    if (_isCheckingOut) {
      return;
    }

    final index = _cart.indexWhere((line) => line.variant.id == variant.id);
    if (index == -1) {
      return;
    }

    final line = _cart[index];
    if (line.quantity <= 1) {
      _cart.removeAt(index);
      _trackCartLineDeleted(line, reason: 'decrement_to_zero');
    } else {
      _cart[index] = line.copyWith(quantity: line.quantity - 1);
    }
    _notifyChanged();
    unawaited(refreshDiscountPreview());
  }

  void removeVariant(ProductVariant variant) {
    if (_isCheckingOut) {
      return;
    }

    final index = _cart.indexWhere((line) => line.variant.id == variant.id);
    if (index == -1) {
      return;
    }

    final line = _cart.removeAt(index);
    _trackCartLineDeleted(line, reason: 'remove_line');
    _notifyChanged();
    unawaited(refreshDiscountPreview());
  }

  void clearCart() {
    if (_isCheckingOut || _cart.isEmpty) {
      return;
    }
    final removedLines = List<CartLine>.of(_cart);
    _cart.clear();
    _couponCode = '';
    _discountPreview = null;
    _hasDiscountPreviewError = false;
    for (final line in removedLines) {
      _trackCartLineDeleted(line, reason: 'clear_cart');
    }
    _notifyChanged();
  }

  bool _addVariantToCart(ProductVariant variant, {int quantity = 1}) {
    if (_isCheckingOut || quantity <= 0) {
      return false;
    }

    final index = _cart.indexWhere((line) => line.variant.id == variant.id);
    if (index == -1) {
      _cart.add(CartLine(variant: variant, quantity: quantity));
    } else {
      final line = _cart[index];
      _cart[index] = line.copyWith(quantity: line.quantity + quantity);
    }
    return true;
  }

  void _trackCartLineDeleted(CartLine line, {required String reason}) {
    final analyticsEngine = _analyticsEngine;
    if (analyticsEngine == null) {
      return;
    }
    final registerSessionId = _activeRegisterSession?.id;
    unawaited(
      analyticsEngine.track(
        AnalyticsEventDraft.audit(
          name: 'pos.cart.line.deleted',
          severity: AnalyticsEventSeverity.warning,
          sessionId: registerSessionId == null
              ? null
              : 'register:$registerSessionId',
          entityType: 'cart_line',
          entityId: '${line.variant.id}',
          attributes: {
            'reason': reason,
            'register_session_id': registerSessionId,
            'product_id': line.variant.productId,
            'variant_id': line.variant.id,
            'product_name': line.variant.productLabel,
            'variant_name': line.variant.variantLabel,
            'sku': line.variant.sku,
          },
          metrics: {
            'quantity': line.quantity,
            'unit_price': line.variant.unitPrice,
            'line_total': line.total,
          },
        ),
      ),
    );
  }
}
