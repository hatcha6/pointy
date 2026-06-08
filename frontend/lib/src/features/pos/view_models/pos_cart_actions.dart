part of 'pos_view_model.dart';

extension PosCartActions on PosViewModel {
  void addVariant(
    ProductVariant variant, {
    int quantity = 1,
    String source = 'cart_quantity_button',
  }) {
    if (_addVariantToCartAndTrack(
      variant,
      quantity: quantity,
      source: source,
    )) {
      _notifyChanged();
      unawaited(refreshDiscountPreview());
    }
  }

  bool _addVariantToCartAndTrack(
    ProductVariant variant, {
    required int quantity,
    required String source,
  }) {
    final existingLine = _cart
        .where((line) => line.variant.id == variant.id)
        .firstOrNull;
    final previousQuantity = existingLine?.quantity ?? 0;
    if (_addVariantToCart(variant, quantity: quantity)) {
      final updatedLine = _cart
          .where((line) => line.variant.id == variant.id)
          .firstOrNull;
      if (updatedLine != null) {
        _trackCartLineAdded(
          updatedLine,
          addedQuantity: quantity,
          previousQuantity: previousQuantity,
          source: source,
        );
      }
      return true;
    }
    return false;
  }

  void decrementVariant(
    ProductVariant variant, {
    String source = 'cart_quantity_button',
  }) {
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
      _trackCartLineDeleted(line, reason: 'decrement_to_zero', source: source);
    } else {
      final updatedLine = line.copyWith(quantity: line.quantity - 1);
      _cart[index] = updatedLine;
      _trackCartLineQuantityChanged(
        updatedLine,
        previousQuantity: line.quantity,
        newQuantity: updatedLine.quantity,
        reason: 'decrement',
        source: source,
      );
    }
    _touchActiveSaleSession();
    _notifyChanged();
    unawaited(refreshDiscountPreview());
  }

  void removeVariant(
    ProductVariant variant, {
    String source = 'cart_delete_button',
  }) {
    if (_isCheckingOut) {
      return;
    }

    final index = _cart.indexWhere((line) => line.variant.id == variant.id);
    if (index == -1) {
      return;
    }

    final line = _cart.removeAt(index);
    _trackCartLineDeleted(line, reason: 'remove_line', source: source);
    _touchActiveSaleSession();
    _notifyChanged();
    unawaited(refreshDiscountPreview());
  }

  void clearCart({String source = 'cart_clear_button'}) {
    if (_isCheckingOut || _cart.isEmpty) {
      return;
    }
    final removedLines = List<CartLine>.of(_cart);
    for (final line in removedLines) {
      _trackCartLineDeleted(line, reason: 'clear_cart', source: source);
    }
    _trackCartCleared(removedLines, source: source);
    _cart.clear();
    _couponCode = '';
    _discountPreview = null;
    _hasDiscountPreviewError = false;
    _touchActiveSaleSession();
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
      final line = _cart.removeAt(index);
      _cart.add(line.copyWith(quantity: line.quantity + quantity));
    }
    _touchActiveSaleSession();
    return true;
  }

  void _trackCartLineAdded(
    CartLine line, {
    required int addedQuantity,
    required int previousQuantity,
    required String source,
  }) {
    final severity = previousQuantity == 0
        ? AnalyticsEventSeverity.info
        : AnalyticsEventSeverity.debug;
    _trackCartAuditEvent(
      name: previousQuantity == 0
          ? 'pos.cart.line.added'
          : 'pos.cart.line.quantity_increased',
      severity: severity,
      line: line,
      attributes: {
        'reason': previousQuantity == 0
            ? 'add_to_cart'
            : 'increment_existing_line',
        'previous_quantity': previousQuantity,
        'new_quantity': line.quantity,
        'added_quantity': addedQuantity,
        'source': source,
      },
      metrics: {
        'quantity': line.quantity,
        'added_quantity': addedQuantity,
        'unit_price': line.variant.unitPrice,
        'line_total': line.total,
      },
    );
  }

  void _trackCartLineQuantityChanged(
    CartLine line, {
    required int previousQuantity,
    required int newQuantity,
    required String reason,
    required String source,
  }) {
    _trackCartAuditEvent(
      name: 'pos.cart.line.quantity_decreased',
      severity: AnalyticsEventSeverity.warning,
      line: line,
      attributes: {
        'reason': reason,
        'previous_quantity': previousQuantity,
        'new_quantity': newQuantity,
        'source': source,
      },
      metrics: {
        'quantity': newQuantity,
        'quantity_delta': newQuantity - previousQuantity,
        'unit_price': line.variant.unitPrice,
        'line_total': line.total,
      },
    );
  }

  void _trackCartLineDeleted(
    CartLine line, {
    required String reason,
    required String source,
  }) {
    _trackCartAuditEvent(
      name: 'pos.cart.line.deleted',
      severity: AnalyticsEventSeverity.warning,
      line: line,
      attributes: {'reason': reason, 'source': source},
      metrics: {
        'quantity': line.quantity,
        'unit_price': line.variant.unitPrice,
        'line_total': line.total,
      },
    );
  }

  void _trackCartCleared(
    List<CartLine> removedLines, {
    required String source,
  }) {
    final analyticsEngine = _analyticsEngine;
    if (analyticsEngine == null) {
      return;
    }
    final registerSessionId = _activeRegisterSession?.id;
    unawaited(
      analyticsEngine.track(
        AnalyticsEventDraft.audit(
          name: 'pos.cart.cleared',
          severity: AnalyticsEventSeverity.warning,
          sessionId: registerSessionId == null
              ? null
              : 'register:$registerSessionId',
          entityType: 'cart',
          attributes: {
            'register_session_id': registerSessionId,
            'source': source,
            'line_count': removedLines.length,
            'item_count': _cartItemCount(removedLines),
            'cart_total': _cartTotal(removedLines),
            'lines': _cartLineSnapshots(removedLines),
          },
          metrics: {
            'line_count': removedLines.length,
            'item_count': _cartItemCount(removedLines),
            'cart_total': _cartTotal(removedLines),
          },
        ),
      ),
    );
  }

  void _trackCartAuditEvent({
    required String name,
    required AnalyticsEventSeverity severity,
    required CartLine line,
    required Map<String, Object?> attributes,
    required Map<String, num> metrics,
  }) {
    final analyticsEngine = _analyticsEngine;
    if (analyticsEngine == null) {
      return;
    }
    final registerSessionId = _activeRegisterSession?.id;
    unawaited(
      analyticsEngine.track(
        AnalyticsEventDraft.audit(
          name: name,
          severity: severity,
          sessionId: registerSessionId == null
              ? null
              : 'register:$registerSessionId',
          entityType: 'cart_line',
          entityId: '${line.variant.id}',
          attributes: {
            ...attributes,
            'register_session_id': registerSessionId,
            'product_id': line.variant.productId,
            'variant_id': line.variant.id,
            'product_name': line.variant.productLabel,
            'variant_name': line.variant.variantLabel,
            'sku': line.variant.sku,
            'cart_line_count': _cart.length,
            'cart_item_count': _cartItemCount(_cart),
            'cart_total': _cartTotal(_cart),
          },
          metrics: {
            ...metrics,
            'cart_line_count': _cart.length,
            'cart_item_count': _cartItemCount(_cart),
            'cart_total': _cartTotal(_cart),
          },
        ),
      ),
    );
  }

  List<Map<String, Object?>> _cartLineSnapshots(List<CartLine> lines) {
    return [
      for (final line in lines.take(50))
        {
          'product_id': line.variant.productId,
          'variant_id': line.variant.id,
          'product_name': line.variant.productLabel,
          'variant_name': line.variant.variantLabel,
          'sku': line.variant.sku,
          'quantity': line.quantity,
          'unit_price': line.variant.unitPrice,
          'line_total': line.total,
        },
    ];
  }

  int _cartItemCount(List<CartLine> lines) {
    return lines.fold(0, (sum, line) => sum + line.quantity);
  }

  double _cartTotal(List<CartLine> lines) {
    return lines.fold(0, (sum, line) => sum + line.total);
  }
}
