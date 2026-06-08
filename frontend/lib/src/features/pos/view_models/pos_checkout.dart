part of 'pos_view_model.dart';

extension PosCheckoutActions on PosViewModel {
  Future<void> refreshDiscountPreview() async {
    final session = _activeSaleSession;
    final requestVersion = ++session.discountPreviewRequestVersion;
    if (session.cart.isEmpty) {
      session.discountPreview = null;
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
      case Error<SaleDiscountPreview>():
        session.discountPreview = null;
        session.hasDiscountPreviewError = true;
    }
    session.isLoadingDiscountPreview = false;
    _notifyChanged();
  }

  List<SaleStockShortage> checkoutStockShortages() {
    final shortages = <SaleStockShortage>[];
    for (final line in _cart) {
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

    final checkoutDraft = SaleCheckoutDraft.fromCart(
      cart: cartSnapshot,
      payments: payments,
      invoicePrinterConfig: backendInvoicePrinterConfig,
      customerId: _selectedCustomer?.id,
      couponCode: _couponCode,
    );
    final checkoutIdempotencyKey = _activeSaleSession.checkoutIdempotencyKeyFor(
      checkoutDraft,
    );

    final result = await _saleRepository.checkout(
      checkoutDraft,
      idempotencyKey: checkoutIdempotencyKey,
    );

    switch (result) {
      case Ok<SaleOrder>():
        final printStatus = shouldPrintInvoice
            ? await _printPaidInvoice(result.value, invoicePrinterConfig)
            : InvoicePrintStatus.notRequested;
        _applySoldQuantities(cartSnapshot);
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

  void _applySoldQuantities(List<CartLine> soldLines) {
    final soldByVariant = <int, int>{};
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
    Map<int, int> soldByVariant,
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
        .fold<int>(0, (sum, entry) => sum + entry.value);
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

int _checkoutCartItemCount(List<CartLine> lines) {
  return lines.fold(0, (sum, line) => sum + line.quantity);
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
    this.order,
    this.printStatus = InvoicePrintStatus.notRequested,
    this.shortages = const [],
    this.lossLines = const [],
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

  final bool isSuccess;
  final bool isStockRejected;
  final bool isLossRejected;
  final SaleOrder? order;
  final InvoicePrintStatus printStatus;
  final List<SaleStockShortage> shortages;
  final List<SaleLossLine> lossLines;
}
