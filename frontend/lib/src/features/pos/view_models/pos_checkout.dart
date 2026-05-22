part of 'pos_view_model.dart';

extension PosCheckoutActions on PosViewModel {
  Future<void> refreshDiscountPreview() async {
    final requestVersion = ++_discountPreviewRequestVersion;
    if (_cart.isEmpty) {
      _discountPreview = null;
      _hasDiscountPreviewError = false;
      _isLoadingDiscountPreview = false;
      _notifyChanged();
      return;
    }

    _isLoadingDiscountPreview = true;
    _hasDiscountPreviewError = false;
    _notifyChanged();

    final result = await _saleRepository.previewDiscounts(
      SaleDiscountPreviewDraft.fromCart(
        cart: List<CartLine>.of(_cart),
        customerId: _selectedCustomer?.id,
        couponCode: _couponCode,
      ),
    );
    if (requestVersion != _discountPreviewRequestVersion) {
      return;
    }

    switch (result) {
      case Ok<SaleDiscountPreview>():
        _discountPreview = result.value;
        _hasDiscountPreviewError = false;
      case Error<SaleDiscountPreview>():
        _discountPreview = null;
        _hasDiscountPreviewError = true;
    }
    _isLoadingDiscountPreview = false;
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
    unawaited(
      _analyticsEngine?.trackUsage(
            AnalyticsEventName.posCheckoutStarted,
            attributes: {
              'line_count': cartSnapshot.length,
              'payment_count': payments.length,
              'has_customer': _selectedCustomer != null,
              'has_coupon': _couponCode.trim().isNotEmpty,
            },
            metrics: {'total': total},
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

    final result = await _saleRepository.checkout(
      SaleCheckoutDraft.fromCart(
        cart: cartSnapshot,
        payments: payments,
        invoicePrinterConfig: invoicePrinterConfig,
        customerId: _selectedCustomer?.id,
        couponCode: _couponCode,
      ),
    );

    switch (result) {
      case Ok<SaleOrder>():
        final printStatus = shouldPrintInvoice
            ? await _printPaidInvoice(result.value, invoicePrinterConfig)
            : InvoicePrintStatus.notRequested;
        _applySoldQuantities(cartSnapshot);
        _cart.clear();
        _selectedCustomer = null;
        _couponCode = '';
        _discountPreview = null;
        _hasDiscountPreviewError = false;
        _printInvoiceAfterPayment = false;
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
                  'line_count': cartSnapshot.length,
                  'payment_count': payments.length,
                  'print_status': printStatus.name,
                  'receipt_number': result.value.receiptNumber,
                },
                metrics: {'total': result.value.total},
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
                  attributes: {'shortage_count': exception.shortages.length},
                  metrics: {'total': total},
                  flushImmediately: true,
                ) ??
                Future<void>.value(),
          );
          return SaleCheckoutOutcome.stockRejected(exception.shortages);
        }
        unawaited(
          _analyticsEngine?.trackPerformance(
                name: analyticsEventNameToJson(
                  AnalyticsEventName.frontendOperation,
                ),
                duration: checkoutStopwatch.elapsed,
                severity: AnalyticsEventSeverity.error,
                attributes: {'operation': 'pos.checkout', 'outcome': 'failure'},
                metrics: {'line_count': cartSnapshot.length, 'total': total},
                flushImmediately: true,
              ) ??
              Future<void>.value(),
        );
        unawaited(
          _analyticsEngine?.captureError(
                exception,
                StackTrace.current,
                name: AnalyticsEventName.posCheckoutFailed,
                attributes: {'line_count': cartSnapshot.length},
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
    final job = order.invoicePrintJob;
    if (config == null || job == null) {
      return InvoicePrintStatus.failed;
    }

    final result = await _printingRepository.printAndReportJob(
      job: job,
      config: config,
    );
    return switch (result) {
      Ok<PrintJob>() => InvoicePrintStatus.printed,
      Error<PrintJob>() => InvoicePrintStatus.failed,
    };
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

enum InvoicePrintStatus { notRequested, printed, failed }

class SaleCheckoutOutcome {
  const SaleCheckoutOutcome._({
    required this.isSuccess,
    required this.isStockRejected,
    this.order,
    this.printStatus = InvoicePrintStatus.notRequested,
    this.shortages = const [],
  });

  const SaleCheckoutOutcome.success(
    SaleOrder order,
    InvoicePrintStatus printStatus,
  ) : this._(
        isSuccess: true,
        isStockRejected: false,
        order: order,
        printStatus: printStatus,
      );

  const SaleCheckoutOutcome.failure()
    : this._(isSuccess: false, isStockRejected: false);

  const SaleCheckoutOutcome.stockRejected(List<SaleStockShortage> shortages)
    : this._(isSuccess: false, isStockRejected: true, shortages: shortages);

  final bool isSuccess;
  final bool isStockRejected;
  final SaleOrder? order;
  final InvoicePrintStatus printStatus;
  final List<SaleStockShortage> shortages;
}
