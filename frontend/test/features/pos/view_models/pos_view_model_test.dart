import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/models/print_job.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/query.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';

void main() {
  test(
    'cart totals update and checkout locks mutations until success',
    () async {
      final checkoutCompleter = Completer<SaleOrder>();
      final apiService = _FakePosApiService(
        checkoutCompleter: checkoutCompleter,
        catalogPages: const {
          1: [_coffee, _tea],
        },
      );
      final viewModel = _viewModel(apiService);
      addTearDown(viewModel.dispose);

      await viewModel.loadCurrentRegisterSession();
      expect(viewModel.availableRegisterSession, isNotNull);
      await viewModel.resumeRegisterSession();
      expect(viewModel.activeRegisterSession, isNotNull);

      viewModel.addProduct(_coffee);
      viewModel.addProduct(_coffee);

      expect(viewModel.cart, hasLength(1));
      expect(viewModel.cart.single.quantity, 2);
      expect(viewModel.subtotal, 7);
      expect(viewModel.total, 7);

      final checkout = viewModel.checkoutCurrentSale(
        payments: const [
          SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 7),
        ],
      );
      await _settle();

      expect(viewModel.isCheckingOut, isTrue);
      expect(apiService.capturedCheckoutDraft?.lines.single.productId, 1);
      expect(apiService.capturedCheckoutDraft?.lines.single.quantity, 2);
      expect(apiService.capturedCheckoutDraft?.payments.single.amount, 7);

      viewModel.addProduct(_tea);
      viewModel.decrementProduct(_coffee);
      viewModel.clearCart();

      expect(viewModel.cart, hasLength(1));
      expect(viewModel.cart.single.product.id, 1);
      expect(viewModel.cart.single.quantity, 2);

      checkoutCompleter.complete(
        _saleOrder(
          total: 7,
          lines: const [
            SaleOrderLine(
              id: 10,
              productId: 1,
              productName: 'قهوة البيت',
              quantity: 2,
              returnedQuantity: 0,
              returnableQuantity: 2,
              unitPrice: 3.5,
              total: 7,
            ),
          ],
        ),
      );

      final outcome = await checkout;

      expect(outcome.isSuccess, isTrue);
      expect(viewModel.isCheckingOut, isFalse);
      expect(viewModel.cart, isEmpty);
      expect(viewModel.products.first.quantityOnHand, 10);
    },
  );

  test(
    'search resets catalog pagination and load more appends results',
    () async {
      final apiService = _FakePosApiService(
        onFetchProducts: (query, page) {
          if (query.search == 'قهوة' && page == 1) {
            return const ProductPage(products: [_coffee], hasMore: true);
          }
          if (query.search == 'قهوة' && page == 2) {
            return const ProductPage(products: [_coffeeBeans], hasMore: false);
          }
          return const ProductPage(products: [_tea], hasMore: false);
        },
      );
      final viewModel = _viewModel(apiService);
      addTearDown(viewModel.dispose);

      await viewModel.loadCurrentRegisterSession();
      await viewModel.resumeRegisterSession();
      final initialRequestCount = apiService.catalogRequests.length;

      await viewModel.updateSearch('قهوة');

      expect(viewModel.query.search, 'قهوة');
      expect(viewModel.products.map((product) => product.id), [1]);
      expect(apiService.catalogRequests.last.page, 1);
      expect(
        apiService.catalogRequests.last.query.availability,
        ProductAvailabilityFilter.active,
      );

      await viewModel.loadMoreCatalog();

      expect(viewModel.products.map((product) => product.id), [1, 3]);
      expect(apiService.catalogRequests.last.page, 2);
      expect(viewModel.hasMoreProducts, isFalse);

      await viewModel.updateSearch('قهوة');

      expect(apiService.catalogRequests.length, initialRequestCount + 2);
    },
  );
}

PosViewModel _viewModel(_FakePosApiService apiService) {
  return PosViewModel(
    CatalogRepository(apiService),
    RegisterSessionRepository(apiService),
    SaleRepository(apiService),
    ShopSettingsRepository(apiService),
    PrintingRepository(
      apiService,
      serialTransport: const _NoopPrintTransport(),
      bluetoothTransport: const _NoopPrintTransport(),
      wifiTransport: const _NoopPrintTransport(),
      fakeTransport: const _NoopPrintTransport(),
    ),
  );
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

SaleOrder _saleOrder({
  required double total,
  required List<SaleOrderLine> lines,
}) {
  return SaleOrder(
    id: 100,
    receiptNumber: 'R-100',
    status: 'paid',
    lines: lines,
    payments: [
      SalePayment(
        id: 1,
        method: PaymentMethod.cash,
        amount: total,
        commissionPercent: 0,
        commissionAmount: 0,
      ),
    ],
    subtotal: total,
    total: total,
  );
}

const _coffee = Product(
  id: 1,
  sku: 'COF-001',
  name: 'قهوة البيت',
  unitPrice: 3.5,
  quantityOnHand: 12,
  barcode: '1000001',
);

const _tea = Product(
  id: 2,
  sku: 'TEA-001',
  name: 'شاي بالنعناع',
  unitPrice: 2.75,
  quantityOnHand: 8,
  barcode: '1000002',
);

const _coffeeBeans = Product(
  id: 3,
  sku: 'COF-002',
  name: 'حبوب قهوة',
  unitPrice: 9,
  quantityOnHand: 5,
  barcode: '1000003',
);

const _openSession = RegisterSession(
  id: 1,
  sessionNumber: 'RS-1',
  status: 'open',
  openingCash: 25,
);

const _settings = ShopSettings(
  shopName: 'نقطة البيع',
  receiptHeader: '',
  receiptFooter: '',
  requireOpeningCash: true,
  autoPrintReceipts: false,
  allowOverselling: false,
  lowStockThreshold: 5,
  cashierReturnWindowHours: 42,
  enableCashPayments: true,
  enableCardPayments: true,
  enableTransferPayments: true,
  cardCommissionPercent: 1,
  transferCommissionPercent: 0,
);

class _CatalogRequest {
  const _CatalogRequest({required this.query, required this.page});

  final ProductQuery query;
  final int page;
}

class _FakePosApiService extends PosApiService {
  _FakePosApiService({
    this.checkoutCompleter,
    this.onFetchProducts,
    this.catalogPages = const {},
  }) : super(
         client: MockClient((_) async => http.Response('{}', 500)),
         baseUrl: 'http://pointy.test/api',
       );

  final Completer<SaleOrder>? checkoutCompleter;
  final ProductPage Function(ProductQuery query, int page)? onFetchProducts;
  final Map<int, List<Product>> catalogPages;
  final List<_CatalogRequest> catalogRequests = [];
  SaleCheckoutDraft? capturedCheckoutDraft;

  @override
  Future<RegisterSession?> fetchCurrentRegisterSession() async {
    return _openSession;
  }

  @override
  Future<ShopSettings> fetchShopSettings() async {
    return _settings;
  }

  @override
  Future<ProductPage> fetchProducts({
    required ModelQuery query,
    int page = 1,
  }) async {
    final productQuery = query as ProductQuery;
    catalogRequests.add(_CatalogRequest(query: productQuery, page: page));
    final customPage = onFetchProducts?.call(productQuery, page);
    if (customPage != null) {
      return customPage;
    }
    return ProductPage(
      products: catalogPages[page] ?? const [],
      hasMore: catalogPages.containsKey(page + 1),
    );
  }

  @override
  Future<SaleOrder> checkout(SaleCheckoutDraft draft) {
    capturedCheckoutDraft = draft;
    final pendingCheckout = checkoutCompleter;
    if (pendingCheckout != null) {
      return pendingCheckout.future;
    }
    final total = draft.payments.fold<double>(
      0,
      (sum, payment) => sum + payment.amount,
    );
    return Future.value(_saleOrder(total: total, lines: const []));
  }
}

class _NoopPrintTransport extends PrintTransport {
  const _NoopPrintTransport();

  @override
  Future<List<PrinterEndpoint>> discover() async {
    return const [];
  }

  @override
  Future<PrintTransportResult> printJob({
    required PrintJob job,
    required PrinterEndpoint endpoint,
  }) async {
    return const PrintTransportResult.success('printed');
  }

  @override
  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async {
    return const PrintTransportResult.success('printed');
  }

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) async {
    return const PrintTransportStatus(isAvailable: true, message: 'ready');
  }
}
