part of 'pos_view_model.dart';

extension PosCheckoutActions on PosViewModel {
  List<SaleStockShortage> checkoutStockShortages() {
    final shortages = <SaleStockShortage>[];
    for (final line in _cart) {
      if (line.quantity > line.product.quantityOnHand) {
        shortages.add(
          SaleStockShortage(
            productName: line.product.name,
            requested: line.quantity,
            available: line.product.quantityOnHand,
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
    final soldByProduct = <int, int>{};
    for (final line in soldLines) {
      soldByProduct[line.product.id] =
          (soldByProduct[line.product.id] ?? 0) + line.quantity;
    }
    if (soldByProduct.isEmpty) {
      return;
    }
    _products = [
      for (final product in _products)
        if (soldByProduct[product.id] case final soldQuantity?)
          product.copyWith(
            quantityOnHand: product.quantityOnHand - soldQuantity,
          )
        else
          product,
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
