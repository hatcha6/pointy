part of 'pos_view_model.dart';

/// Add sources that arm the type-a-quantity shortcut, exactly like a hardware
/// scan does: picking a product from the catalog then typing "12" sets the new
/// line's quantity — no extra tap on the cart line.
const _quickQuantityAddSources = {
  'product_tile',
  'variant_picker',
  'camera_scanner',
};

extension PosCartActions on PosViewModel {
  void addVariant(
    ProductVariant variant, {
    double quantity = 1,
    List<CartLineModifier> modifiers = const [],
    UnitOption? unit,
    String source = 'cart_quantity_button',
  }) {
    if (_addVariantToCartAndTrack(
      variant,
      quantity: quantity,
      modifiers: modifiers,
      unit: unit,
      source: source,
    )) {
      if (_quickQuantityAddSources.contains(source)) {
        _lastScannedLineKey = _mergeableLineFor(
          variant,
          modifiers,
          _unitCodeFor(unit),
        )?.lineKey;
        _quickQuantityBuffer = '';
        _quickQuantityAt = null;
      }
      _notifyChanged();
      unawaited(refreshDiscountPreview());
    }
  }

  bool _addVariantToCartAndTrack(
    ProductVariant variant, {
    required double quantity,
    List<CartLineModifier> modifiers = const [],
    UnitOption? unit,
    required String source,
  }) {
    final unitCode = _unitCodeFor(unit);
    final existingLine = _mergeableLineFor(variant, modifiers, unitCode);
    final previousQuantity = existingLine?.quantity ?? 0;
    if (_addVariantToCart(
      variant,
      quantity: quantity,
      modifiers: modifiers,
      unit: unit,
    )) {
      final updatedLine = _mergeableLineFor(variant, modifiers, unitCode);
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

  // A non-base unit becomes the line's [CartLine.unitCode]; the base unit stays
  // blank so it merges with plain adds and serialises as the product default.
  String _unitCodeFor(UnitOption? unit) =>
      (unit == null || unit.isBase) ? '' : unit.code;

  /// The line a fresh add of [variant] should merge into: same variant, no
  /// kitchen note, the same modifier selection, and the same unit. A noted line,
  /// a different modifier choice ("oat" vs "whole"), or a different unit ("box"
  /// vs "piece") stays separate so it never absorbs a plain add.
  CartLine? _mergeableLineFor(
    ProductVariant variant,
    List<CartLineModifier> modifiers,
    String unitCode,
  ) {
    final signature = _modifierSignature(modifiers);
    return _cart
        .where(
          (line) =>
              line.variant.id == variant.id &&
              line.notes.isEmpty &&
              line.modifierSignature == signature &&
              line.unitCode == unitCode,
        )
        .firstOrNull;
  }

  String _modifierSignature(List<CartLineModifier> modifiers) {
    final parts =
        modifiers
            .map((modifier) => '${modifier.optionId}:${modifier.quantity}')
            .toList()
          ..sort();
    return parts.join(',');
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

  /// Removes a line and returns it with its prior index so the caller can offer
  /// an undo. Returns null when nothing matched (or checkout is in progress).
  ({CartLine line, int index})? removeCartLine(
    String lineKey, {
    String source = 'cart_delete_button',
  }) {
    if (_isCheckingOut) {
      return null;
    }
    final index = _cart.indexWhere((line) => line.lineKey == lineKey);
    if (index == -1) {
      return null;
    }
    final line = _cart.removeAt(index);
    _trackCartLineDeleted(line, reason: 'remove_line', source: source);
    _touchActiveSaleSession();
    _notifyChanged();
    unawaited(refreshDiscountPreview());
    return (line: line, index: index);
  }

  /// Re-inserts a line removed via [removeCartLine] at its original position
  /// (clamped if the cart changed meanwhile). Backs the cart-line undo action.
  void restoreCartLine(CartLine line, int index) {
    if (_isCheckingOut) {
      return;
    }
    final position = index < 0
        ? 0
        : (index > _cart.length ? _cart.length : index);
    _cart.insert(position, line);
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

  bool _addVariantToCart(
    ProductVariant variant, {
    double quantity = 1,
    List<CartLineModifier> modifiers = const [],
    UnitOption? unit,
  }) {
    if (_isCheckingOut || quantity <= 0) {
      return false;
    }

    final signature = _modifierSignature(modifiers);
    final unitCode = _unitCodeFor(unit);
    final index = _cart.indexWhere(
      (line) =>
          line.variant.id == variant.id &&
          line.notes.isEmpty &&
          line.modifierSignature == signature &&
          line.unitCode == unitCode,
    );
    if (index == -1) {
      _cart.add(
        CartLine.create(
          variant: variant,
          quantity: quantity,
          modifiers: modifiers,
          unitCode: unitCode,
          unitLabel: unit?.label ?? '',
          unitFactor: unit?.factorToBase ?? 1,
          unitPriceOverride: (unit == null || unit.isBase)
              ? null
              : unit.unitPrice,
        ),
      );
    } else {
      // Merge in place: a line's position is set on first insertion and never
      // changes afterwards — re-adds and quantity edits must not shuffle the
      // list under the cashier's eyes.
      final line = _cart[index];
      _cart[index] = line.copyWith(quantity: line.quantity + quantity);
    }
    _touchActiveSaleSession();
    return true;
  }

  /// Switches the unit a cart line is sold in (used from the cart). Changes the
  /// per-unit price and stock conversion, so the discount preview is refreshed.
  void setCartLineUnit(String lineKey, UnitOption unit) {
    if (_isCheckingOut) {
      return;
    }
    final index = _cart.indexWhere((line) => line.lineKey == lineKey);
    if (index == -1) {
      return;
    }
    final line = _cart[index];
    final isBase = unit.isBase;
    _cart[index] = line.copyWith(
      unitCode: isBase ? '' : unit.code,
      unitLabel: unit.label,
      unitFactor: unit.factorToBase,
      unitPriceOverride: isBase ? null : unit.unitPrice,
    );
    _touchActiveSaleSession();
    _notifyChanged();
    unawaited(refreshDiscountPreview());
  }

  /// Replaces the modifier selection on a cart line (used when editing from the
  /// cart). Modifiers affect price, so the discount preview is refreshed.
  void setCartLineModifiers(String lineKey, List<CartLineModifier> modifiers) {
    if (_isCheckingOut) {
      return;
    }
    final index = _cart.indexWhere((line) => line.lineKey == lineKey);
    if (index == -1) {
      return;
    }
    _cart[index] = _cart[index].copyWith(modifiers: modifiers);
    _touchActiveSaleSession();
    _notifyChanged();
    unawaited(refreshDiscountPreview());
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
