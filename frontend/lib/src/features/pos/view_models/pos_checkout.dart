part of 'pos_view_model.dart';

extension PosCheckoutActions on PosViewModel {
  /// True when a live preview confirmed the shop has no active sale discount
  /// rules AND the server's pushed discounts version still matches — i.e. the
  /// preview is pure arithmetic the client can do itself.
  bool get discountRulesKnownInactive {
    final latched = _noActiveDiscountRulesVersion;
    final current = _saleRepository.discountsVersionToken;
    return latched != null && current != null && latched == current;
  }

  Future<void> refreshDiscountPreview({bool forceServer = false}) async {
    final session = _activeSaleSession;
    final requestVersion = ++session.discountPreviewRequestVersion;
    if (session.cart.isEmpty) {
      session.discountPreview = null;
      session.hasDiscountPreviewError = false;
      session.isLoadingDiscountPreview = false;
      _notifyChanged();
      return;
    }

    final couponCode = session.couponCode.trim();
    if (!forceServer && couponCode.isEmpty && discountRulesKnownInactive) {
      // No rules exist (confirmed at the pushed discounts version): totals
      // are plain sums, so skip the network entirely. No request means the
      // preview can never fail on a shop that runs no promotions.
      session.discountPreview = _localNoRulesPreview(session);
      session.hasDiscountPreviewError = false;
      session.isLoadingDiscountPreview = false;
      _notifyChanged();
      return;
    }

    session.isLoadingDiscountPreview = true;
    session.hasDiscountPreviewError = false;
    _notifyChanged();

    final result = await _saleRepository.previewDiscounts(
      SaleDiscountPreviewDraft.fromCart(
        cart: List<CartLine>.of(session.cart),
        customerId: session.selectedCustomer?.id,
        couponCode: session.couponCode,
      ),
    );
    if (requestVersion != session.discountPreviewRequestVersion) {
      return;
    }

    switch (result) {
      case Ok<SaleDiscountPreview>():
        session.discountPreview = result.value;
        session.hasDiscountPreviewError = false;
        _latchDiscountRulesGate(result.value);
      case Error<SaleDiscountPreview>():
        if (couponCode.isEmpty && discountRulesKnownInactive) {
          // Transient failure, but nothing depends on the server: no coupon
          // to validate and no rules that could change the totals. Fail soft
          // with the local arithmetic instead of nagging the cashier.
          session.discountPreview = _localNoRulesPreview(session);
          session.hasDiscountPreviewError = false;
        } else {
          session.discountPreview = null;
          session.hasDiscountPreviewError = true;
        }
    }
    session.isLoadingDiscountPreview = false;
    _notifyChanged();
  }

  void _latchDiscountRulesGate(SaleDiscountPreview preview) {
    if (!preview.rulesActive && preview.rulesVersion.isNotEmpty) {
      _noActiveDiscountRulesVersion = preview.rulesVersion;
    } else if (preview.rulesActive) {
      _noActiveDiscountRulesVersion = null;
    }
  }

  SaleDiscountPreview _localNoRulesPreview(_PosSaleSession session) {
    final subtotal = session.cart.fold<double>(
      0,
      (sum, line) => sum + line.total,
    );
    return SaleDiscountPreview(
      subtotal: subtotal,
      discountTotal: 0,
      total: subtotal,
      rulesActive: false,
      rulesVersion: _noActiveDiscountRulesVersion ?? '',
    );
  }

  List<SaleStockShortage> checkoutStockShortages() {
    final shortages = <SaleStockShortage>[];
    for (final line in _cart) {
      // Mirror the backend: services have no stock and made-to-order
      // (prepared) products consume their recipe ingredients instead of their
      // own stock, so neither can ever be a shortage. See
      // prepare_sale_stock_adjustments in apps/sales/services.py.
      if (line.variant.isService || line.variant.isPrepared) {
        continue;
      }
      if (line.quantity > line.variant.quantityOnHand) {
        shortages.add(
          SaleStockShortage(
            productName: line.variant.displayLabel,
            requested: line.quantity,
            available: line.variant.quantityOnHand,
          ),
        );
      }
    }
    return shortages;
  }

  List<SaleLossLine> checkoutLossLines() {
    return _discountPreview?.lossLines ?? const [];
  }

  Future<SaleCheckoutOutcome> checkoutCurrentSale({
    required List<SaleCheckoutPaymentDraft> payments,
    SaleType saleType = SaleType.standard,
    DateTime? validUntil,
    bool reserveStock = false,
    bool printProof = false,
  }) async {
    if (_isCheckingOut) {
      return const SaleCheckoutOutcome.failure();
    }
    if (_activeRegisterSession == null || _cart.isEmpty) {
      return const SaleCheckoutOutcome.failure();
    }

    _isCheckingOut = true;
    _notifyChanged();

    final checkoutStopwatch = Stopwatch()..start();
    final cartSnapshot = List<CartLine>.of(_cart);
    final customerSnapshot = _selectedCustomer;
    final couponCodeSnapshot = _couponCode.trim();
    unawaited(
      _analyticsEngine?.trackUsage(
            AnalyticsEventName.posCheckoutStarted,
            attributes: {
              'register_session_id': _activeRegisterSession?.id,
              'line_count': cartSnapshot.length,
              'item_count': _checkoutCartItemCount(cartSnapshot),
              'payment_count': payments.length,
              'has_customer': customerSnapshot != null,
              'customer_id': customerSnapshot?.id,
              'customer_name': customerSnapshot?.fullName,
              'has_coupon': couponCodeSnapshot.isNotEmpty,
              'coupon_code_present': couponCodeSnapshot.isNotEmpty,
              'cart_total': _checkoutCartTotal(cartSnapshot),
              'lines': _checkoutCartLineSnapshots(cartSnapshot),
            },
            metrics: {
              'line_count': cartSnapshot.length,
              'item_count': _checkoutCartItemCount(cartSnapshot),
              'payment_count': payments.length,
              'total': total,
            },
          ) ??
          Future<void>.value(),
    );
    // Any +/- run still open belongs to the sale being rung up, not the next
    // one: emit it before the checkout event so the order reads correctly.
    _cartQuantityRuns.settleAll();
    final shouldPrintInvoice =
        _checkoutSettings?.autoPrintReceipts == true ||
        _printInvoiceAfterPayment;
    PrinterConfig? invoicePrinterConfig;
    if (shouldPrintInvoice) {
      final configResult = await _printingRepository.loadDefaultPrinterConfig();
      switch (configResult) {
        case Ok<PrinterConfig>():
          invoicePrinterConfig = configResult.value;
        case Error<PrinterConfig>():
          invoicePrinterConfig = null;
      }
    }
    final backendInvoicePrinterConfig =
        invoicePrinterConfig?.endpoint.usesThermalReceipt == true
        ? invoicePrinterConfig
        : null;
    // Only a raw-thermal printer goes through the backend's print queue; a
    // driver/PDF one is driven from here (see _printPaidInvoice) and never
    // touches it. Say which, so the backend does not mint a queue row nothing
    // will ever read — 24,264 of those accumulated in the field while every
    // receipt printed perfectly by the local route. Left null when we are not
    // printing at all, so the backend keeps its own agent-based judgement.
    SaleCheckoutDraft buildCheckoutDraft(PrinterConfig? printerConfig) {
      return SaleCheckoutDraft.fromCart(
        cart: cartSnapshot,
        payments: payments,
        invoicePrinterConfig: printerConfig,
        customerId: _selectedCustomer?.id,
        couponCode: _couponCode,
        saleType: saleType,
        validUntil: validUntil,
        reserveStock: reserveStock,
        // Derived from the config being sent, not from whatever resolves right
        // now, so a retry carries the first attempt's routing like the rest of
        // the body does.
        receiptDelivery: !shouldPrintInvoice
            ? null
            : printerConfig != null
            ? ReceiptDelivery.agent
            : ReceiptDelivery.local,
      );
    }

    // A retry of this same sale must reach the backend as the *same* request:
    // the same key so it replays, and the same body so it isn't refused as a
    // conflicting reuse of that key. The attempt therefore carries the print
    // routing of the first send, and it is that routing — not whatever resolved
    // this time round — that goes back out (shop settings that failed to reload
    // during the outage, a printer reconfigured between attempts).
    final attempt = _activeSaleSession.checkoutAttemptFor(
      buildCheckoutDraft(backendInvoicePrinterConfig),
    );
    final checkoutDraft = buildCheckoutDraft(attempt.invoicePrinterConfig);
    // Get the key on disk before the request leaves. Everything after this
    // point can be interrupted by a mains cut, and the cart comes back on the
    // next launch — without the key beside it the cashier's retry would book a
    // second sale. Best-effort: a till that can't write its scratch state still
    // has to be able to take the money.
    await persistNow();

    final result = await _saleRepository.checkout(
      checkoutDraft,
      idempotencyKey: attempt.idempotencyKey,
    );

    switch (result) {
      case Ok<SaleOrder>():
        // The sale is committed on the backend at this point, so every print
        // step below is strictly best-effort: each runs behind a bounded,
        // failure-swallowing guard so a stalled printer (offline-but-listening,
        // out of paper, a wedged OS spooler) can never freeze the just-completed
        // checkout. Without this, a print that hangs would leave `_isCheckingOut`
        // stuck true and the whole POS locked. See [_guardedPrintValue].
        // ONE shared budget for every post-sale print step combined. Each step
        // draws from the same deadline, so a stalled printer can delay the
        // already-committed checkout by at most _checkoutPrintDeadline in total
        // — not per step. Previously each of the invoice / kitchen / proof
        // steps got its own full deadline, so two hung printers summed to ~2x
        // and froze the POS for ~40s (the checkout-hang tail seen in the field).
        final printDeadline = DateTime.now().add(_checkoutPrintDeadline);
        final printStatus = shouldPrintInvoice
            ? await _guardedPrintValue(
                () => _printPaidInvoice(result.value, invoicePrinterConfig),
                fallback: InvoicePrintStatus.failed,
                label: 'invoice',
                order: result.value,
                deadline: printDeadline,
              )
            : InvoicePrintStatus.notRequested;
        if (_checkoutSettings?.autoPrintKitchenTickets == true) {
          await _guardedPrintVoid(
            () => _printPaidKitchenTickets(result.value),
            label: 'kitchen_tickets',
            order: result.value,
            deadline: printDeadline,
          );
        }
        if (printProof) {
          // Hand the customer a سند قبض for the credit down-payment(s) just
          // taken. Best-effort — the sale is already committed.
          await _guardedPrintVoid(
            () => _printDownPaymentProofs(result.value),
            label: 'down_payment_proof',
            order: result.value,
            deadline: printDeadline,
          );
        }
        // A quotation moves no stock on the backend, so don't optimistically
        // decrement the local catalog either (a held quotation reserves, not
        // sells; the next catalog refresh reflects any hold).
        if (saleType != SaleType.quotation) {
          _applySoldQuantities(cartSnapshot);
        }
        _completeActiveSaleSessionCheckout();
        _isCheckingOut = false;
        _notifyChanged();
        unawaited(
          _analyticsEngine?.trackPerformance(
                name: analyticsEventNameToJson(
                  AnalyticsEventName.frontendOperation,
                ),
                duration: checkoutStopwatch.elapsed,
                attributes: {'operation': 'pos.checkout', 'outcome': 'success'},
                metrics: {
                  'line_count': cartSnapshot.length,
                  'item_count': _checkoutCartItemCount(cartSnapshot),
                  'total': result.value.total,
                },
                entityType: 'sale_order',
                entityId: result.value.id.toString(),
              ) ??
              Future<void>.value(),
        );
        unawaited(
          _analyticsEngine?.trackUsage(
                AnalyticsEventName.posCheckoutCompleted,
                attributes: {
                  'register_session_id': _activeRegisterSession?.id,
                  'line_count': cartSnapshot.length,
                  'item_count': _checkoutCartItemCount(cartSnapshot),
                  'payment_count': payments.length,
                  'print_status': printStatus.name,
                  'receipt_number': result.value.receiptNumber,
                  'customer_id': result.value.customer,
                  'customer_name':
                      result.value.customerName ?? customerSnapshot?.fullName,
                  'coupon_code_present': couponCodeSnapshot.isNotEmpty,
                  'cart_total': _checkoutCartTotal(cartSnapshot),
                  'lines': _checkoutCartLineSnapshots(cartSnapshot),
                },
                metrics: {
                  'line_count': cartSnapshot.length,
                  'item_count': _checkoutCartItemCount(cartSnapshot),
                  'payment_count': payments.length,
                  'total': result.value.total,
                },
                entityType: 'sale_order',
                entityId: result.value.id.toString(),
                flushImmediately: true,
              ) ??
              Future<void>.value(),
        );
        return SaleCheckoutOutcome.success(result.value, printStatus);
      case Error<SaleOrder>(:final exception):
        _isCheckingOut = false;
        _notifyChanged();
        if (exception is SaleCheckoutNoSessionException) {
          // The cached register session is gone on the backend. Drop it so the
          // POS shows the open-session gate, and re-sync from the server.
          _activeRegisterSession = null;
          _notifyChanged();
          unawaited(loadCurrentRegisterSession());
          unawaited(
            _analyticsEngine?.trackUsage(
                  AnalyticsEventName.posCheckoutFailed,
                  severity: AnalyticsEventSeverity.warning,
                  attributes: {
                    'failure_reason': 'register_session_missing',
                    'line_count': cartSnapshot.length,
                  },
                  metrics: {'line_count': cartSnapshot.length},
                  flushImmediately: true,
                ) ??
                Future<void>.value(),
          );
          return const SaleCheckoutOutcome.sessionExpired();
        }
        if (exception is SaleCheckoutStockException) {
          unawaited(
            _analyticsEngine?.trackPerformance(
                  name: analyticsEventNameToJson(
                    AnalyticsEventName.frontendOperation,
                  ),
                  duration: checkoutStopwatch.elapsed,
                  severity: AnalyticsEventSeverity.warning,
                  attributes: {
                    'operation': 'pos.checkout',
                    'outcome': 'stock_rejected',
                  },
                  metrics: {
                    'shortage_count': exception.shortages.length,
                    'line_count': cartSnapshot.length,
                    'item_count': _checkoutCartItemCount(cartSnapshot),
                    'total': total,
                  },
                  flushImmediately: true,
                ) ??
                Future<void>.value(),
          );
          unawaited(
            _analyticsEngine?.trackUsage(
                  AnalyticsEventName.posCheckoutStockRejected,
                  severity: AnalyticsEventSeverity.warning,
                  attributes: {
                    'register_session_id': _activeRegisterSession?.id,
                    'shortage_count': exception.shortages.length,
                    'line_count': cartSnapshot.length,
                    'item_count': _checkoutCartItemCount(cartSnapshot),
                    'cart_total': _checkoutCartTotal(cartSnapshot),
                    'lines': _checkoutCartLineSnapshots(cartSnapshot),
                  },
                  metrics: {
                    'shortage_count': exception.shortages.length,
                    'line_count': cartSnapshot.length,
                    'item_count': _checkoutCartItemCount(cartSnapshot),
                    'total': total,
                  },
                  flushImmediately: true,
                ) ??
                Future<void>.value(),
          );
          return SaleCheckoutOutcome.stockRejected(exception.shortages);
        }
        if (exception is SaleCheckoutLossException) {
          unawaited(
            _analyticsEngine?.trackUsage(
                  AnalyticsEventName.posCheckoutFailed,
                  severity: AnalyticsEventSeverity.warning,
                  attributes: {
                    'register_session_id': _activeRegisterSession?.id,
                    'failure_reason': 'loss_rejected',
                    'loss_line_count': exception.lossLines.length,
                    'line_count': cartSnapshot.length,
                    'item_count': _checkoutCartItemCount(cartSnapshot),
                    'cart_total': _checkoutCartTotal(cartSnapshot),
                    'lines': _checkoutCartLineSnapshots(cartSnapshot),
                  },
                  metrics: {
                    'loss_line_count': exception.lossLines.length,
                    'line_count': cartSnapshot.length,
                    'item_count': _checkoutCartItemCount(cartSnapshot),
                    'total': total,
                  },
                  flushImmediately: true,
                ) ??
                Future<void>.value(),
          );
          return SaleCheckoutOutcome.lossRejected(exception.lossLines);
        }
        if (exception is SaleCheckoutCreditLimitException) {
          unawaited(
            _analyticsEngine?.trackUsage(
                  AnalyticsEventName.posCheckoutFailed,
                  severity: AnalyticsEventSeverity.warning,
                  attributes: {
                    'register_session_id': _activeRegisterSession?.id,
                    'failure_reason': 'credit_limit_rejected',
                    'line_count': cartSnapshot.length,
                  },
                  metrics: {
                    'credit_limit': exception.limit,
                    'credit_outstanding': exception.outstanding,
                    'credit_new_debt': exception.newDebt,
                    'total': total,
                  },
                  flushImmediately: true,
                ) ??
                Future<void>.value(),
          );
          return SaleCheckoutOutcome.creditLimitRejected(exception);
        }
        unawaited(
          _analyticsEngine?.trackPerformance(
                name: analyticsEventNameToJson(
                  AnalyticsEventName.frontendOperation,
                ),
                duration: checkoutStopwatch.elapsed,
                severity: AnalyticsEventSeverity.error,
                attributes: {'operation': 'pos.checkout', 'outcome': 'failure'},
                metrics: {
                  'line_count': cartSnapshot.length,
                  'item_count': _checkoutCartItemCount(cartSnapshot),
                  'total': total,
                },
                flushImmediately: true,
              ) ??
              Future<void>.value(),
        );
        unawaited(
          _analyticsEngine?.captureError(
                exception,
                StackTrace.current,
                name: AnalyticsEventName.posCheckoutFailed,
                attributes: {
                  'register_session_id': _activeRegisterSession?.id,
                  'failure_reason': 'checkout_error',
                  'line_count': cartSnapshot.length,
                  'item_count': _checkoutCartItemCount(cartSnapshot),
                  'cart_total': _checkoutCartTotal(cartSnapshot),
                  'lines': _checkoutCartLineSnapshots(cartSnapshot),
                },
              ) ??
              Future<void>.value(),
        );
        return const SaleCheckoutOutcome.failure();
    }
  }

  /// Prints the kitchen chits this device is responsible for. The backend
  /// enqueues one job per routed station; this device prints only the stations
  /// it has a local thermal printer configured for and leaves the rest queued.
  /// Skips silently when no kitchen station is configured here.
  Future<void> _printPaidKitchenTickets(SaleOrder order) async {
    final jobs = order.kitchenPrintJobs;
    if (jobs.isEmpty) {
      return;
    }
    final stationConfigs = await _printingRepository
        .loadKitchenStationConfigs();
    if (stationConfigs.isEmpty) {
      return;
    }
    for (final job in jobs) {
      final stationId = _kitchenJobStationId(job);
      if (stationId == null) {
        continue;
      }
      final config = stationConfigs[stationId];
      if (config == null || !config.endpoint.usesThermalReceipt) {
        continue;
      }
      await _printingRepository.claimAndPrintKitchenJob(
        job: job,
        config: config,
      );
    }
  }

  int? _kitchenJobStationId(PrintJob job) {
    final station = job.payload['station'];
    if (station is Map<String, Object?>) {
      final id = station['id'];
      if (id is int) {
        return id;
      }
      return int.tryParse('${id ?? ''}');
    }
    return null;
  }

  /// Runs a best-effort, value-returning post-sale print [action] behind a hard
  /// [_checkoutPrintDeadline], swallowing any failure or timeout and returning
  /// [fallback] instead. This is what keeps a committed sale from ever being
  /// held hostage by a stalled printer.
  Future<T> _guardedPrintValue<T>(
    Future<T> Function() action, {
    required T fallback,
    required String label,
    required SaleOrder order,
    required DateTime deadline,
  }) async {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _reportPrintStepFailure(
        label,
        order,
        TimeoutException('checkout print budget exhausted'),
        StackTrace.current,
      );
      return fallback;
    }
    try {
      return await action().timeout(remaining);
    } on Object catch (error, stackTrace) {
      _reportPrintStepFailure(label, order, error, stackTrace);
      return fallback;
    }
  }

  /// [_guardedPrintValue] for print steps that return nothing (kitchen chits,
  /// down-payment proofs). A failure/timeout is logged and swallowed so it can
  /// neither throw out of checkout nor hang it.
  Future<void> _guardedPrintVoid(
    Future<void> Function() action, {
    required String label,
    required SaleOrder order,
    required DateTime deadline,
  }) async {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _reportPrintStepFailure(
        label,
        order,
        TimeoutException('checkout print budget exhausted'),
        StackTrace.current,
      );
      return;
    }
    try {
      await action().timeout(remaining);
    } on Object catch (error, stackTrace) {
      _reportPrintStepFailure(label, order, error, stackTrace);
    }
  }

  void _reportPrintStepFailure(
    String label,
    SaleOrder order,
    Object error,
    StackTrace stackTrace,
  ) {
    unawaited(
      _analyticsEngine?.captureError(
            error,
            stackTrace,
            severity: AnalyticsEventSeverity.warning,
            attributes: {
              'failure_reason': 'checkout_print_step_failed',
              'print_step': label,
              'sale_order_id': order.id,
              'receipt_number': order.receiptNumber,
            },
          ) ??
          Future<void>.value(),
    );
  }

  Future<InvoicePrintStatus> _printPaidInvoice(
    SaleOrder order,
    PrinterConfig? config,
  ) async {
    if (config == null) {
      return InvoicePrintStatus.failed;
    }

    if (config.endpoint.usesDocumentInvoice) {
      final result = await _printingRepository.printSaleInvoice(
        order: order,
        shopSettings: _checkoutSettings,
        shopLogoBytes: _checkoutShopLogoBytes,
      );
      return result.isSuccess
          ? InvoicePrintStatus.printed
          : InvoicePrintStatus.failed;
    }

    final job = order.invoicePrintJob;
    if (job != null) {
      final result = await _printingRepository.printAndReportJob(
        job: job,
        config: config,
        requeueOnFailure: true,
      );
      return switch (result) {
        Ok<PrintJob>() => InvoicePrintStatus.printed,
        Error<PrintJob>() => InvoicePrintStatus.failed,
      };
    }

    final result = await _printingRepository.printSaleInvoice(
      order: order,
      shopSettings: _checkoutSettings,
      shopLogoBytes: _checkoutShopLogoBytes,
    );
    return result.isSuccess
        ? InvoicePrintStatus.printed
        : InvoicePrintStatus.failed;
  }

  /// Prints a "سند قبض" proof for each down-payment recorded at credit
  /// checkout — one slip per tender, so a split down-payment yields one
  /// receipt per method. The repository records a payment_receipt audit event
  /// per slip (keyed on the payment id). Mirrors the invoice-details proof.
  Future<void> _printDownPaymentProofs(SaleOrder order) async {
    if (order.payments.isEmpty) {
      return;
    }
    const labels = OrderDocumentLabels.arabic();
    for (final payment in order.payments) {
      final proof = PaymentProof(
        kind: PaymentProofKind.receipt,
        reference: '${payment.id}',
        partyName: (order.customerName?.trim().isNotEmpty ?? false)
            ? order.customerName!.trim()
            : labels.walkInCustomer,
        partyContact: order.customerPhone?.trim().isNotEmpty == true
            ? order.customerPhone!.trim()
            : order.customerNumber,
        relatedDocumentNumber: order.receiptNumber,
        amount: payment.amount,
        method: labels.paymentMethodLabel(payment.method),
        commissionAmount: payment.commissionAmount,
        externalReference: payment.externalReference,
        balanceAfter: order.balanceDue,
        createdAt: payment.createdAt ?? DateTime.now(),
      );
      await _printingRepository.printProofOfPayment(
        proof: proof,
        paymentId: payment.id,
        paymentKind: PrintAuditPaymentKind.customer,
        shopSettings: _checkoutSettings,
        shopLogoBytes: _checkoutShopLogoBytes,
      );
    }
  }

  void _applySoldQuantities(List<CartLine> soldLines) {
    final soldByVariant = <int, double>{};
    for (final line in soldLines) {
      soldByVariant[line.variant.id] =
          (soldByVariant[line.variant.id] ?? 0) + line.quantity;
    }
    if (soldByVariant.isEmpty) {
      return;
    }
    _products = [
      for (final product in _products)
        _productWithAdjustedStock(product, soldByVariant),
    ];
  }

  Product _productWithAdjustedStock(
    Product product,
    Map<int, double> soldByVariant,
  ) {
    ProductVariant adjustVariant(ProductVariant variant) {
      final soldQuantity = soldByVariant[variant.id];
      if (soldQuantity == null) {
        return variant;
      }
      return variant.copyWith(
        quantityOnHand: variant.quantityOnHand - soldQuantity,
      );
    }

    final adjustedVariants = [
      for (final variant in product.variants) adjustVariant(variant),
    ];
    final adjustedDefaultVariant = product.defaultVariant == null
        ? null
        : adjustVariant(product.defaultVariant!);
    final soldForProduct = soldByVariant.entries
        .where(
          (entry) =>
              product.variants.any((variant) => variant.id == entry.key) ||
              product.defaultVariant?.id == entry.key,
        )
        .fold<double>(0, (sum, entry) => sum + entry.value);
    return product.copyWith(
      quantityOnHand: product.quantityOnHand - soldForProduct,
      defaultVariant: adjustedDefaultVariant,
      variants: adjustedVariants,
    );
  }
}

List<Map<String, Object?>> _checkoutCartLineSnapshots(List<CartLine> lines) {
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

double _checkoutCartItemCount(List<CartLine> lines) {
  return lines.fold(0.0, (sum, line) => sum + line.quantity);
}

double _checkoutCartTotal(List<CartLine> lines) {
  return lines.fold(0, (sum, line) => sum + line.total);
}

enum InvoicePrintStatus { notRequested, printed, failed }

class SaleCheckoutOutcome {
  const SaleCheckoutOutcome._({
    required this.isSuccess,
    required this.isStockRejected,
    required this.isLossRejected,
    this.isSessionExpired = false,
    this.order,
    this.printStatus = InvoicePrintStatus.notRequested,
    this.shortages = const [],
    this.lossLines = const [],
    this.creditLimit,
  });

  const SaleCheckoutOutcome.success(
    SaleOrder order,
    InvoicePrintStatus printStatus,
  ) : this._(
        isSuccess: true,
        isStockRejected: false,
        isLossRejected: false,
        order: order,
        printStatus: printStatus,
      );

  const SaleCheckoutOutcome.failure()
    : this._(isSuccess: false, isStockRejected: false, isLossRejected: false);

  const SaleCheckoutOutcome.sessionExpired()
    : this._(
        isSuccess: false,
        isStockRejected: false,
        isLossRejected: false,
        isSessionExpired: true,
      );

  const SaleCheckoutOutcome.stockRejected(List<SaleStockShortage> shortages)
    : this._(
        isSuccess: false,
        isStockRejected: true,
        isLossRejected: false,
        shortages: shortages,
      );

  const SaleCheckoutOutcome.lossRejected(List<SaleLossLine> lossLines)
    : this._(
        isSuccess: false,
        isStockRejected: false,
        isLossRejected: true,
        lossLines: lossLines,
      );

  const SaleCheckoutOutcome.creditLimitRejected(
    SaleCheckoutCreditLimitException creditLimit,
  ) : this._(
        isSuccess: false,
        isStockRejected: false,
        isLossRejected: false,
        creditLimit: creditLimit,
      );

  final bool isSuccess;
  final bool isStockRejected;
  final bool isLossRejected;
  final bool isSessionExpired;
  final SaleOrder? order;
  final InvoicePrintStatus printStatus;
  final List<SaleStockShortage> shortages;
  final List<SaleLossLine> lossLines;

  /// Set when the آجل sale was refused for breaching the customer's ceiling.
  final SaleCheckoutCreditLimitException? creditLimit;

  bool get isCreditLimitRejected => creditLimit != null;
}
