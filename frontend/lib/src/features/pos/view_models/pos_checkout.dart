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

    final cartSnapshot = List<CartLine>.of(_cart);
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
        return SaleCheckoutOutcome.success(result.value, printStatus);
      case Error<SaleOrder>(:final exception):
        _isCheckingOut = false;
        _notifyChanged();
        if (exception is SaleCheckoutStockException) {
          return SaleCheckoutOutcome.stockRejected(exception.shortages);
        }
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
    _variants = [
      for (final variant in _variants)
        if (soldByVariant[variant.id] case final soldQuantity?)
          variant.copyWith(
            quantityOnHand: variant.quantityOnHand - soldQuantity,
          )
        else
          variant,
    ];
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
