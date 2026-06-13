part of 'pos_view_model.dart';

extension PosCartActions on PosViewModel {
  void addVariant(
    ProductVariant variant, {
    double quantity = 1,
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
    required double quantity,
    required String source,
  }) {
    final existingLine = _mergeableLineFor(variant);
    final previousQuantity = existingLine?.quantity ?? 0;
    if (_addVariantToCart(variant, quantity: quantity)) {
      final updatedLine = _mergeableLineFor(variant);
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

  /// The line a fresh add of [variant] should merge into: same variant and no
  /// kitchen note. A noted line ("burger / no onions") stays separate so it
  /// never absorbs a plain add.
  CartLine? _mergeableLineFor(ProductVariant variant) {
    return _cart
        .where((line) => line.variant.id == variant.id && line.notes.isEmpty)
        .firstOrNull;
  }

  // Per-line mutations key on the stable [CartLine.lineKey] so two lines of the
  // same variant (one noted, one not) are edited independently.

  void incrementCartLine(
    String lineKey, {
    String source = 'cart_quantity_button',
  }) {
    if (_isCheckingOut) {
      return;
    }
    final index = _cart.indexWhere((line) => line.lineKey == lineKey);
    if (index == -1) {
      return;
    }
    final line = _cart[index];
    final updatedLine = line.copyWith(quantity: line.quantity + 1);
    _cart[index] = updatedLine;
    _trackCartLineQuantityChanged(
      updatedLine,
      previousQuantity: line.quantity,
      newQuantity: updatedLine.quantity,
      reason: 'increment',
      source: source,
    );
    _touchActiveSaleSession();
    _notifyChanged();
    unawaited(refreshDiscountPreview());
  }

  void decrementCartLine(
    String lineKey, {
    String source = 'cart_quantity_button',
  }) {
    if (_isCheckingOut) {
      return;
    }
    final index = _cart.indexWhere((line) => line.lineKey == lineKey);
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

  void setCartLineQuantity(
    String lineKey,
    double quantity, {
    String source = 'cart_weight_edit',
  }) {
    if (_isCheckingOut || quantity <= 0) {
      return;
    }
    final index = _cart.indexWhere((line) => line.lineKey == lineKey);
    if (index == -1) {
      return;
    }
    final line = _cart[index];
    if (line.quantity == quantity) {
      return;
    }
    final updatedLine = line.copyWith(quantity: quantity);
    _cart[index] = updatedLine;
    _trackCartLineQuantityChanged(
      updatedLine,
      previousQuantity: line.quantity,
      newQuantity: quantity,
      reason: 'weight_edit',
      source: source,
    );
    _touchActiveSaleSession();
    _notifyChanged();
    unawaited(refreshDiscountPreview());
  }

  void removeCartLine(
    String lineKey, {
    String source = 'cart_delete_button',
  }) {
    if (_isCheckingOut) {
      return;
    }
    final index = _cart.indexWhere((line) => line.lineKey == lineKey);
    if (index == -1) {
      return;
    }
    final line = _cart.removeAt(index);
    _trackCartLineDeleted(line, reason: 'remove_line', source: source);
    _touchActiveSaleSession();
    _notifyChanged();
    unawaited(refreshDiscountPreview());
  }

  /// Attaches (or clears) the free-text kitchen note on a cart line. Notes do
  /// not affect pricing, so there is no discount refresh.
  void setCartLineNote(
    String lineKey,
    String note, {
    String source = 'cart_line_note',
  }) {
    if (_isCheckingOut) {
      return;
    }
    final index = _cart.indexWhere((line) => line.lineKey == lineKey);
    if (index == -1) {
      return;
    }
    final line = _cart[index];
    final normalized = note.trim();
    if (line.notes == normalized) {
      return;
    }
    _cart[index] = line.copyWith(notes: normalized);
    _touchActiveSaleSession();
    _notifyChanged();
  }

  // Variant-keyed wrappers kept for the product grid and existing callers; they
  // resolve to the first line of the variant, then delegate to the line-keyed
  // mutation above.

  void decrementVariant(
    ProductVariant variant, {
    String source = 'cart_quantity_button',
  }) {
    final line = _cart
        .where((line) => line.variant.id == variant.id)
        .firstOrNull;
    if (line == null) {
      return;
    }
    decrementCartLine(line.lineKey, source: source);
  }

  void setVariantQuantity(
    ProductVariant variant,
    double quantity, {
    String source = 'cart_weight_edit',
  }) {
    final line = _cart
        .where((line) => line.variant.id == variant.id)
        .firstOrNull;
    if (line == null) {
      return;
    }
    setCartLineQuantity(line.lineKey, quantity, source: source);
  }

  void removeVariant(
    ProductVariant variant, {
    String source = 'cart_delete_button',
  }) {
    final line = _cart
        .where((line) => line.variant.id == variant.id)
        .firstOrNull;
    if (line == null) {
      return;
    }
    removeCartLine(line.lineKey, source: source);
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

  bool _addVariantToCart(ProductVariant variant, {double quantity = 1}) {
    if (_isCheckingOut || quantity <= 0) {
      return false;
    }

    final index = _cart.indexWhere(
      (line) => line.variant.id == variant.id && line.notes.isEmpty,
    );
    if (index == -1) {
      _cart.add(CartLine.create(variant: variant, quantity: quantity));
    } else {
      final line = _cart.removeAt(index);
      _cart.add(line.copyWith(quantity: line.quantity + quantity));
    }
    _touchActiveSaleSession();
    return true;
  }

  void _trackCartLineAdded(
    CartLine line, {
    required double addedQuantity,
    required double previousQuantity,
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
    required double previousQuantity,
    required double newQuantity,
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

  double _cartItemCount(List<CartLine> lines) {
    return lines.fold(0.0, (sum, line) => sum + line.quantity);
  }

  double _cartTotal(List<CartLine> lines) {
    return lines.fold(0, (sum, line) => sum + line.total);
  }
}
