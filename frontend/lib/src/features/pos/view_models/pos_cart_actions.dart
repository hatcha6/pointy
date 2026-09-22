part of 'pos_view_model.dart';

/// Add sources that mark the new line as the active line for the keyboard
/// shortcuts (F2 cycle-unit / F4 delete / arrow cycle-unit), exactly like a
/// hardware scan does — so picking a product from the catalog then pressing F2
/// cycles that line's unit with no extra tap.
const _activeLineAddSources = {
  'product_tile',
  'variant_picker',
  'camera_scanner',
};

/// What a run of +/- presses on one cart line adds up to.
class _CartQuantityRun {
  _CartQuantityRun({
    required this.line,
    required this.startQuantity,
    required this.endQuantity,
    required this.reason,
    required this.source,
  });

  CartLine line;
  final double startQuantity;
  double endQuantity;
  final String reason;
  final String source;

  /// How many times the cashier changed their mind mid-run — up then down.
  int reversals = 0;

  void absorb({required CartLine line, required double newQuantity}) {
    final wasRising = endQuantity >= startQuantity;
    final nowRising = newQuantity >= endQuantity;
    if (endQuantity != newQuantity && wasRising != nowRising) {
      reversals += 1;
    }
    this.line = line;
    endQuantity = newQuantity;
  }
}

extension PosCartActions on PosViewModel {
  void addVariant(
    ProductVariant variant, {
    double quantity = 1,
    List<CartLineModifier> modifiers = const [],
    UnitOption? unit,
    StockUnit? stockUnit,
    StockBatch? stockBatch,
    String source = 'cart_quantity_button',
  }) {
    if (_addVariantToCartAndTrack(
      variant,
      quantity: quantity,
      modifiers: modifiers,
      unit: unit,
      stockUnit: stockUnit,
      stockBatch: stockBatch,
      source: source,
    )) {
      if (_activeLineAddSources.contains(source)) {
        _activeCartLineKey = stockUnit != null
            ? _cart.lastOrNull?.lineKey
            : _mergeableLineFor(
                variant,
                modifiers,
                _unitCodeFor(unit),
              )?.lineKey;
        // A grid tap, variant pick, or camera scan is a discrete "add" gesture:
        // hand keyboard focus back to the search field so the cashier can look
        // up or scan the next item without reaching for the mouse. The field
        // ignores the request while a sheet is still up.
        _searchFocusController.requestFocus();
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
    StockUnit? stockUnit,
    StockBatch? stockBatch,
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
      stockUnit: stockUnit,
      stockBatch: stockBatch,
    )) {
      // An identified article never merges, so the line it created is the last
      // one; anything else is found by its merge key as before.
      final updatedLine = stockUnit != null
          ? _cart.lastOrNull
          : _mergeableLineFor(variant, modifiers, unitCode);
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
              line.unitCode == unitCode &&
              // One article is one article. A serialized line names a specific
              // handset, so a second handset of the same model is a second
              // line — never a quantity of two, which would be a claim to hold
              // two devices with the same IMEI.
              !line.isSerialized &&
              // Same reasoning for a top-up: each one is its own purchase from
              // the provider, with its own cost and its own confirmation.
              !line.isIntegrationRecharge,
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
    // One article is one article. A serialized line's quantity is not the
    // cashier's to change: raising it would be a claim to hold two devices with
    // the same identifier, and the cart's own `+`/`-` hotkeys ride the scan
    // listener, so the refusal has to live here rather than only in the widget.
    if (!line.allowsQuantityEdit) {
      return;
    }
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
      // The line is going away: emit whatever run was open on it first, so the
      // run and the delete read in the order they happened.
      _cartQuantityRuns.settle(line.lineKey);
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

  /// Pin a lot to a cart line, or clear the pin and let the till pick again.
  ///
  /// Clearing is not the same as picking nothing: it hands the choice back to
  /// first-expiring-first-out at checkout, which is the answer a pharmacy wants
  /// nine times out of ten.
  void setCartLineBatch(String lineKey, StockBatch? batch) {
    if (_isCheckingOut) {
      return;
    }
    final index = _cart.indexWhere((line) => line.lineKey == lineKey);
    if (index == -1) {
      return;
    }
    _cart[index] = _cart[index].copyWith(
      stockBatchId: batch?.id,
      stockBatchCode: batch?.label ?? '',
      stockBatchExpiry: batch?.expiryDate,
    );
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
    // One article is one article. A serialized line's quantity is not the
    // cashier's to change: raising it would be a claim to hold two devices with
    // the same identifier, and the cart's own `+`/`-` hotkeys ride the scan
    // listener, so the refusal has to live here rather than only in the widget.
    if (!line.allowsQuantityEdit) {
      return;
    }
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
    _cartQuantityRuns.settle(line.lineKey);
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
    // Settle before the deletes so a run in progress is still attributed to the
    // line it happened on.
    _cartQuantityRuns.settleAll();
    for (final line in removedLines) {
      _trackCartLineDeleted(line, reason: 'clear_cart', source: source);
    }
    _trackCartCleared(removedLines, source: source);
    _cart.clear();
    _couponCode = '';
    // The haggle belonged to the basket that just went away. Carrying it over
    // would take money off the next customer's sale without anybody deciding to.
    _extraDiscountAmount = 0;
    _discountPreview = null;
    _hasDiscountPreviewError = false;
    _touchActiveSaleSession();
    // The cart is now empty and ready for the next scan/lookup — return focus to
    // the search field (the confirm dialog has already closed by this point).
    _searchFocusController.requestFocus();
    _notifyChanged();
  }

  bool _addVariantToCart(
    ProductVariant variant, {
    double quantity = 1,
    List<CartLineModifier> modifiers = const [],
    UnitOption? unit,
    StockUnit? stockUnit,
    StockBatch? stockBatch,
  }) {
    if (_isCheckingOut || quantity <= 0) {
      return false;
    }

    final signature = _modifierSignature(modifiers);
    final unitCode = _unitCodeFor(unit);
    final index = stockUnit != null
        // An identified article never merges into anything, and nothing merges
        // into it: the line IS the handset.
        ? -1
        : _cart.indexWhere(
            (line) =>
                line.variant.id == variant.id &&
                line.notes.isEmpty &&
                line.modifierSignature == signature &&
                line.unitCode == unitCode &&
                !line.isSerialized &&
                // A line pinned to a lot only merges with one pinned to the
                // same lot; leaving that to FEFO and pinning it are two
                // different instructions.
                line.stockBatchId == stockBatch?.id,
          );
    if (index == -1) {
      _cart.add(
        CartLine.create(
          variant: variant,
          quantity: stockUnit == null ? quantity : 1,
          modifiers: modifiers,
          unitCode: unitCode,
          unitLabel: unit?.label ?? '',
          unitFactor: unit?.factorToBase ?? 1,
          unitPriceOverride:
              stockUnit?.listPrice ??
              ((unit == null || unit.isBase) ? null : unit.unitPrice),
          stockUnitId: stockUnit?.id,
          stockUnitCode: stockUnit?.code ?? '',
          stockBatchId: stockBatch?.id,
          stockBatchCode: stockBatch?.label ?? '',
          stockBatchExpiry: stockBatch?.expiryDate,
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

  /// Puts a provider top-up in the cart.
  ///
  /// The line is an ordinary service-product line — that is what keeps
  /// discounts, receipts, returns and the profit report working without any of
  /// them learning what a recharge is — carrying the provider's own details
  /// alongside. It never merges with anything: each top-up is its own purchase
  /// from the provider, with its own cost and its own confirmation.
  ///
  /// The price shown here is what the server quoted for this shop's markup.
  /// The server recomputes it at checkout; this is display, not instruction.
  void addIntegrationRecharge(IntegrationRechargeDraft draft) {
    if (_isCheckingOut) {
      return;
    }
    final service = draft.serviceVariant;
    _cart.add(
      CartLine.create(
        variant: ProductVariant(
          id: service.id,
          productId: service.productId,
          sku: service.sku,
          unitPrice: draft.price,
          productName: service.name,
          displayName: service.name,
          fullName: service.name,
          isService: true,
          isDefault: true,
        ),
        quantity: 1,
        integration: CartLineIntegration(
          provider: integrationProviderKeyToJson(draft.provider),
          subscriberRef: draft.subscriberRef,
          optionCode: draft.offer.code,
          optionLabel: draft.offer.label,
          cost: draft.cost,
          months: draft.offer.months,
          packageId: draft.offer.packageId,
          packageName: draft.offer.packageName,
        ),
      ),
    );
    _touchActiveSaleSession();
    _notifyChanged();
    unawaited(refreshDiscountPreview());
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

  /// Sets (or clears) the price a cashier typed for a cart line.
  ///
  /// Passing null puts the line back on the shop's own price, which is what
  /// makes a mis-typed figure recoverable without deleting the line and
  /// scanning it again with a customer waiting.
  ///
  /// The client does not enforce the permission — the server refuses an
  /// override from anyone without `sales.override_line_price`, and refuses it
  /// rather than quietly charging the shelf price. This only hides the
  /// affordance from people who cannot use it.
  void setCartLinePrice(String lineKey, double? unitPrice) {
    if (_isCheckingOut) {
      return;
    }
    final index = _cart.indexWhere((line) => line.lineKey == lineKey);
    if (index == -1) {
      return;
    }
    final line = _cart[index];
    // A price equal to what it would have sold for anyway is not an override:
    // recording it as one would put a repriced badge on a line nobody changed.
    final normalized = unitPrice == null || unitPrice == line.listUnitPrice
        ? null
        : unitPrice;
    if (normalized == line.manualUnitPrice) {
      return;
    }
    _cart[index] = line.copyWith(manualUnitPrice: normalized);
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

  /// Folds a quantity change into the line's open run instead of recording it.
  ///
  /// Holding +/- produced one analytics row per repeat: 93.9% of cart quantity
  /// events in the field arrived within 250ms of the previous one on the same
  /// line. None of them said anything the run did not — what matters is that
  /// the cashier took a line from 1 to 7, not the six presses on the way. The
  /// settled event carries both ends, the step count, and how many times the
  /// direction reversed, which is strictly more than the stream of singles
  /// could say.
  void _trackCartLineQuantityChanged(
    CartLine line, {
    required double previousQuantity,
    required double newQuantity,
    required String reason,
    required String source,
  }) {
    _cartQuantityRuns.add(
      line.lineKey,
      start: () => _CartQuantityRun(
        line: line,
        startQuantity: previousQuantity,
        endQuantity: newQuantity,
        reason: reason,
        source: source,
      ),
      merge: (run) => run..absorb(line: line, newQuantity: newQuantity),
    );
  }

  void _emitCartQuantityRun(
    String key,
    CoalescedBurst<_CartQuantityRun> burst,
  ) {
    final run = burst.value;
    final delta = run.endQuantity - run.startQuantity;
    if (delta == 0) {
      // Pressed up and back down to where it started: nothing changed, and a
      // row saying so is the noise this exists to remove.
      return;
    }
    _trackCartAuditEvent(
      // One name for both directions. The previous code emitted
      // `quantity_decreased` for increments too — every +/- press, either way,
      // was filed as a decrease at warning severity, which is why the field
      // counts for the two directions could not be read against each other.
      name: 'pos.cart.line.quantity_settled',
      severity: AnalyticsEventSeverity.debug,
      line: run.line,
      attributes: {
        'reason': run.reason,
        'source': run.source,
        'direction': delta > 0 ? 'increase' : 'decrease',
        'previous_quantity': run.startQuantity,
        'new_quantity': run.endQuantity,
        // A run that changed direction is a cashier overshooting and coming
        // back — the signal that says the press-and-hold is too eager.
        'reversed': run.reversals > 0,
      },
      metrics: {
        'quantity': run.endQuantity,
        'quantity_delta': delta,
        'step_count': burst.count,
        'reversals': run.reversals,
        'duration_ms': burst.duration.inMilliseconds,
        'unit_price': run.line.variant.unitPrice,
        'line_total': run.line.total,
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
