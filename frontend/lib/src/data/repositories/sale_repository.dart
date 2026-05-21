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
  final int requested;
  final int available;
}

class SaleCheckoutStockException implements Exception {
  const SaleCheckoutStockException(this.shortages);

  final List<SaleStockShortage> shortages;
}

class SaleRepository {
  SaleRepository(this._service);

  final PosApiService _service;

  Future<Result<SaleOrder>> checkout(SaleCheckoutDraft draft) async {
    try {
      return Ok(await _service.checkout(draft));
    } on PosApiException catch (exception) {
      final shortages = _stockShortagesFromException(exception);
      if (shortages.isNotEmpty) {
        return Error(SaleCheckoutStockException(shortages));
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

  Future<Result<SaleOrderPage>> loadOrdersForSession(
    int sessionId, {
    SaleOrderQuery query = const SaleOrderQuery(),
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchRegisterSessionOrders(
        sessionId,
        query: query,
        page: page,
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
            requested: _intFromJson(item['requested']),
            available: _intFromJson(item['available']),
          );
        })
        .toList(growable: false);
  }

  int _intFromJson(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
