import '../../core/result.dart';
import '../models/print_job.dart';
import '../models/sale_order.dart';
import '../models/sale_order_page.dart';
import '../services/pos_api_service.dart';

class SaleStockShortage {
  const SaleStockShortage({
    required this.productName,
    required this.requested,
    required this.available,
  });

  final String productName;
  final double requested;
  final double available;
}

class SaleCheckoutStockException implements Exception {
  const SaleCheckoutStockException(this.shortages);

  final List<SaleStockShortage> shortages;
}

class SaleCheckoutLossException implements Exception {
  const SaleCheckoutLossException(this.lossLines);

  final List<SaleLossLine> lossLines;
}

/// The آجل sale would put the customer past their credit ceiling. Carries the
/// server's numbers so the till can say *why* rather than only "refused".
class SaleCheckoutCreditLimitException implements Exception {
  const SaleCheckoutCreditLimitException({
    required this.limit,
    required this.outstanding,
    required this.available,
    required this.newDebt,
    required this.projected,
  });

  final double limit;
  final double outstanding;
  final double available;
  final double newDebt;
  final double projected;
}

/// The backend has no open register session for this request owner — the
/// frontend's cached session is stale (closed elsewhere, or the data was
/// reset). The POS must send the user back to open a fresh session.
class SaleCheckoutNoSessionException implements Exception {
  const SaleCheckoutNoSessionException();
}

class SaleRepository {
  SaleRepository(this._service);

  final PosApiService _service;

  /// The backend's pushed discounts version (see PosApiSession) — the POS
  /// latches "no active rules" against it to skip preview requests.
  String? get discountsVersionToken => _service.discountsVersionToken;

  Future<Result<void>> sendInvoiceSms(int saleOrderId) {
    return Result.guard(() => _service.sendInvoiceSms(saleOrderId));
  }

  Future<Result<SaleOrder>> checkout(
    SaleCheckoutDraft draft, {
    String? idempotencyKey,
  }) async {
    try {
      return Ok(await _service.checkout(draft, idempotencyKey: idempotencyKey));
    } on PosApiException catch (exception) {
      final shortages = _stockShortagesFromException(exception);
      if (shortages.isNotEmpty) {
        return Error(SaleCheckoutStockException(shortages));
      }
      final lossLines = _lossLinesFromException(exception);
      if (lossLines.isNotEmpty) {
        return Error(SaleCheckoutLossException(lossLines));
      }
      final creditLimit = _creditLimitFromException(exception);
      if (creditLimit != null) {
        return Error(creditLimit);
      }
      if (_isNoOpenSessionError(exception)) {
        return const Error(SaleCheckoutNoSessionException());
      }
      return Error(exception);
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<SaleDiscountPreview>> previewDiscounts(
    SaleDiscountPreviewDraft draft,
  ) async {
    return Result.guard(() => _service.previewSaleDiscounts(draft));
  }

  Future<Result<SaleOrderPage>> loadOrders({
    SaleOrderQuery query = const SaleOrderQuery(),
    int page = 1,
  }) async {
    return Result.guard(() => _service.fetchOrders(query: query, page: page));
  }

  Future<Result<SaleOrder>> loadOrder(int saleOrderId) async {
    return Result.guard(() => _service.fetchOrder(saleOrderId));
  }

  /// Records a payment against a single (credit) invoice. Cards are allowed —
  /// pass [cardReceiptUrl] for the card method.
  Future<Result<SaleOrder>> recordInvoicePayment({
    required int saleOrderId,
    required String method,
    required double amount,
    String cardReceiptUrl = '',
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.recordInvoicePayment(
        saleOrderId,
        method: method,
        amount: amount,
        cardReceiptUrl: cardReceiptUrl,
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  /// Assigns or changes the customer who owes a debt (credit) invoice. The
  /// backend rejects this once any payment has been recorded against it.
  Future<Result<SaleOrder>> assignInvoiceCustomer({
    required int saleOrderId,
    required int customerId,
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.assignSaleOrderCustomer(
        saleOrderId,
        customerId: customerId,
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  /// Converts an OPEN quotation into a standard or credit sale, optionally
  /// taking a down-payment ([amountReceived]). Returns the NEW order.
  Future<Result<SaleOrder>> convertQuotation(
    int orderId, {
    required SaleType saleType,
    double? amountReceived,
    String? idempotencyKey,
  }) async {
    return Result.guard(
      () => _service.convertQuotation(
        orderId,
        saleType: saleType,
        amountReceived: amountReceived,
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  Future<Result<SaleOrderPage>> loadOrdersForSession(
    int sessionId, {
    SaleOrderQuery query = const SaleOrderQuery(),
    String? cursor,
  }) async {
    return Result.guard(
      () => _service.fetchRegisterSessionOrders(
        sessionId,
        query: query,
        cursor: cursor,
      ),
    );
  }

  Future<Result<PrintJob>> requestReprint(int saleOrderId) async {
    return Result.guard(() => _service.requestSaleReprint(saleOrderId));
  }

  Future<Result<SaleOrder>> voidOrder({
    required int saleOrderId,
    required SaleVoidDraft draft,
  }) async {
    return Result.guard(
      () => _service.voidSaleOrder(saleOrderId: saleOrderId, draft: draft),
    );
  }

  Future<Result<SaleOrder>> returnItems({
    required int saleOrderId,
    required SaleReturnDraft draft,
  }) async {
    return Result.guard(
      () =>
          _service.returnSaleOrderItems(saleOrderId: saleOrderId, draft: draft),
    );
  }

  Future<Result<SaleOrder>> exchangeItems({
    required int saleOrderId,
    required SaleExchangeDraft draft,
  }) async {
    return Result.guard(
      () => _service.exchangeSaleOrderItems(
        saleOrderId: saleOrderId,
        draft: draft,
      ),
    );
  }

  Future<Result<SaleOrder>> lookupByReceipt(String receiptNumber) async {
    return Result.guard(() => _service.lookupSaleOrderByReceipt(receiptNumber));
  }

  List<SaleStockShortage> _stockShortagesFromException(
    PosApiException exception,
  ) {
    if (exception.statusCode != 400) {
      return const [];
    }
    final decoded = exception.decodedBody;
    if (decoded is! Map<String, Object?>) {
      return const [];
    }
    final stock = decoded['stock'];
    if (stock is! List<Object?>) {
      return const [];
    }
    return stock
        .whereType<Map<String, Object?>>()
        .map((item) {
          return SaleStockShortage(
            productName:
                item['variant_name']?.toString() ??
                item['product_name']?.toString() ??
                '',
            requested: _shortageQtyFromJson(item['requested']),
            available: _shortageQtyFromJson(item['available']),
          );
        })
        .toList(growable: false);
  }

  bool _isNoOpenSessionError(PosApiException exception) {
    if (exception.statusCode != 400) {
      return false;
    }
    final decoded = exception.decodedBody;
    if (decoded is! Map<String, Object?>) {
      return false;
    }
    final detail = decoded['detail']?.toString().toLowerCase() ?? '';
    return detail.contains('register session');
  }

  SaleCheckoutCreditLimitException? _creditLimitFromException(
    PosApiException exception,
  ) {
    if (exception.statusCode != 400) {
      return null;
    }
    final decoded = exception.decodedBody;
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    final credit = decoded['credit'];
    if (credit is! Map<String, Object?>) {
      return null;
    }
    return SaleCheckoutCreditLimitException(
      limit: _shortageQtyFromJson(credit['limit']),
      outstanding: _shortageQtyFromJson(credit['outstanding']),
      available: _shortageQtyFromJson(credit['available']),
      newDebt: _shortageQtyFromJson(credit['new_debt']),
      projected: _shortageQtyFromJson(credit['projected']),
    );
  }

  List<SaleLossLine> _lossLinesFromException(PosApiException exception) {
    if (exception.statusCode != 400) {
      return const [];
    }
    final decoded = exception.decodedBody;
    if (decoded is! Map<String, Object?>) {
      return const [];
    }
    final loss = decoded['loss'];
    if (loss is! List<Object?>) {
      return const [];
    }
    return loss
        .whereType<Map<String, Object?>>()
        .map(SaleLossLine.fromJson)
        .toList(growable: false);
  }
}

double _shortageQtyFromJson(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse((value ?? 0).toString()) ?? 0;
}
