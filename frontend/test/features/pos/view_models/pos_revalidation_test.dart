import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/core/revalidation.dart';
import 'package:pointy_frontend/src/core/server_state.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/print_job.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/query.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_revalidation.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';

/// Long enough to clear the revalidator's debounce (400ms) — the window that
/// collapses a burst of bumps into one refresh — plus the refresh itself.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 600));

void main() {
  late _FakePosApiService api;
  late PosViewModel pos;
  late Revalidator revalidator;

  setUp(() async {
    api = _FakePosApiService();
    pos = PosViewModel(
      CatalogRepository(api),
      RegisterSessionRepository(api),
      SaleRepository(api),
      ShopSettingsRepository(api),
      PrintingRepository(
        api,
        serialTransport: const _NoopPrintTransport(),
        bluetoothTransport: const _NoopPrintTransport(),
        wifiTransport: const _NoopPrintTransport(),
        fakeTransport: const _NoopPrintTransport(),
      ),
      sessionStorage: MemoryScopedJsonStorage(),
    );
    revalidator = Revalidator(api.serverState);
    registerPosRevalidation(revalidator: revalidator, posViewModel: pos);
    // The vector's first sighting is never a change, so seed it the way a
    // real till does: from the responses its opening loads receive.
    api.serverState.apply({
      ServerStateDomain.settings: '1',
      ServerStateDomain.catalogDefs: '1',
      ServerStateDomain.catalog: '1',
      ServerStateDomain.stock: '1',
    });
  });

  tearDown(() {
    revalidator.dispose();
    pos.dispose();
  });

  test('a price edited elsewhere reaches the sell screen', () async {
    // The complaint this whole mechanism answers: the back office changes a
    // price, and the till goes on quoting the old one until someone restarts.
    await pos.loadCatalog();
    expect(pos.products.single.defaultVariant!.unitPrice, 3.5);

    api.variantPrice = 4.25;
    api.serverState.apply({ServerStateDomain.catalogDefs: '2'});
    await _settle();

    expect(pos.products.single.defaultVariant!.unitPrice, 4.25);
  });

  test('a rename reaches it the same way', () async {
    await pos.loadCatalog();
    api.variantName = 'قهوة تركية';
    api.serverState.apply({ServerStateDomain.catalogDefs: '2'});
    await _settle();

    expect(pos.products.single.name, 'قهوة تركية');
  });

  test('a settings change reaches the till', () async {
    await pos.loadCheckoutSettings();
    // The checkbox is shown only while the shop is NOT auto-printing, so it
    // reads the setting the till actually acts on.
    expect(pos.shouldShowPrintInvoiceCheckbox, isTrue);

    api.settings = _settingsWith(autoPrint: true);
    api.serverState.apply({ServerStateDomain.settings: '2'});
    await _settle();

    expect(pos.shouldShowPrintInvoiceCheckbox, isFalse);
  });

  test('stock moving does not churn the sell screen', () async {
    // Every checkout in the shop moves the stock counter. If that refreshed
    // the grid, a busy floor would re-read the catalog all day.
    await pos.loadCatalog();
    final requestsAfterLoad = api.catalogRequests;

    api.serverState.apply({
      ServerStateDomain.stock: '2',
      ServerStateDomain.catalog: '2',
    });
    await _settle();

    expect(api.catalogRequests, requestsAfterLoad);
  });

  test('a refresh waits while a scan is resolving, then lands', () async {
    await pos.loadCatalog();
    final resolving = Completer<void>();
    api.holdBarcodeResolution = resolving.future;

    unawaited(pos.addVariantByBarcode('1000001'));
    await _settle();
    expect(pos.isResolvingBarcode, isTrue);

    api.variantPrice = 9.0;
    api.serverState.apply({ServerStateDomain.catalogDefs: '2'});
    await _settle();
    expect(
      pos.products.single.defaultVariant!.unitPrice,
      3.5,
      reason: 'the grid must not move under a scan',
    );

    resolving.complete();
    await _settle();
    expect(
      pos.products.single.defaultVariant!.unitPrice,
      9.0,
      reason: 'the held refresh lands once the scan settles',
    );
  });

  test('a refresh is held through a critical interaction', () async {
    // What the payment sheet and the quantity editor open and close.
    await pos.loadCatalog();
    pos.beginCriticalInteraction();

    api.variantPrice = 7.0;
    api.serverState.apply({ServerStateDomain.catalogDefs: '2'});
    await _settle();
    expect(pos.products.single.defaultVariant!.unitPrice, 3.5);

    pos.endCriticalInteraction();
    await _settle();
    expect(pos.products.single.defaultVariant!.unitPrice, 7.0);
  });

  test('a background refresh raises no loading state', () async {
    // A skeleton thrown over a populated grid mid-shift is worse than the
    // staleness it fixes.
    await pos.loadCatalog();
    final loadingStates = <bool>[];
    pos.addListener(() => loadingStates.add(pos.isLoading));

    api.serverState.apply({ServerStateDomain.catalogDefs: '2'});
    await _settle();

    expect(loadingStates, isNotEmpty);
    expect(loadingStates, everyElement(isFalse));
  });

  test('a failed refresh leaves the screen as it was', () async {
    await pos.loadCatalog();
    api.failCatalog = true;

    api.serverState.apply({ServerStateDomain.catalogDefs: '2'});
    await _settle();

    expect(pos.products, hasLength(1));
    expect(pos.errorMessage, isNull);
  });

  test('an open cart does not block a refresh', () async {
    // Carts stay open for minutes. A cashier mid-sale is exactly who must not
    // be shown last week's price on the next item they add.
    await pos.loadCurrentRegisterSession();
    await pos.resumeRegisterSession();
    await pos.loadCatalog();
    pos.addVariant(_coffeeVariant, source: 'product_tile');
    await _settle();
    expect(pos.cart, isNotEmpty);

    api.variantPrice = 5.5;
    api.serverState.apply({ServerStateDomain.catalogDefs: '2'});
    await _settle();

    expect(pos.products.single.defaultVariant!.unitPrice, 5.5);
    expect(pos.cart, hasLength(1), reason: 'the cart itself is untouched');
  });
}

const _coffeeVariant = ProductVariant(
  id: 101,
  productId: 1,
  productName: 'قهوة البيت',
  displayName: 'قهوة البيت',
  fullName: 'قهوة البيت',
  sku: 'COF-001',
  unitPrice: 3.5,
  quantityOnHand: 12,
  barcode: '1000001',
  isDefault: true,
);

ShopSettings _settingsWith({required bool autoPrint}) => ShopSettings(
  shopName: 'نقطة البيع',
  receiptHeader: '',
  receiptFooter: '',
  enableOnlineInvoices: false,
  requireOpeningCash: true,
  autoPrintReceipts: autoPrint,
  allowOverselling: true,
  preventSellingAtLoss: true,
  lowStockThreshold: 5,
  cashierReturnWindowHours: 42,
  enableCashPayments: true,
  enableCardPayments: true,
  enableTransferPayments: true,
  requireCardPaymentReceipt: false,
  trustedCardTerminalIds: const [],
  cardCommissionPercent: 1,
  transferCommissionPercent: 0,
);

class _FakePosApiService extends PosApiService {
  _FakePosApiService()
    : super(
        client: MockClient((_) async => http.Response('{}', 500)),
        baseUrl: 'http://pointy.test/api',
      );

  double variantPrice = 3.5;
  String variantName = 'قهوة البيت';
  bool failCatalog = false;
  int catalogRequests = 0;
  Future<void>? holdBarcodeResolution;
  ShopSettings settings = _settingsWith(autoPrint: false);

  @override
  Future<ShopSettings> fetchShopSettings() async => settings;

  @override
  Future<RegisterSession?> fetchCurrentRegisterSession() async =>
      const RegisterSession(
        id: 1,
        sessionNumber: 'RS-1',
        status: 'open',
        openingCash: 25,
      );

  @override
  Future<ProductPage> fetchProducts({
    required ModelQuery query,
    int page = 1,
  }) async {
    catalogRequests += 1;
    if (failCatalog) {
      throw Exception('backend unreachable');
    }
    if (page > 1) {
      return const ProductPage(products: [], hasMore: false);
    }
    return ProductPage(
      products: [
        Product.fromVariant(
          ProductVariant(
            id: _coffeeVariant.id,
            productId: _coffeeVariant.productId,
            productName: variantName,
            displayName: variantName,
            fullName: variantName,
            sku: _coffeeVariant.sku,
            unitPrice: variantPrice,
            quantityOnHand: _coffeeVariant.quantityOnHand,
            barcode: _coffeeVariant.barcode,
            isDefault: true,
          ),
        ),
      ],
      hasMore: false,
    );
  }

  @override
  Future<ProductVariantPage> fetchProductVariants({
    required ModelQuery query,
    int page = 1,
  }) async {
    final hold = holdBarcodeResolution;
    if (hold != null) {
      await hold;
    }
    return const ProductVariantPage(variants: [], hasMore: false);
  }
}

class _NoopPrintTransport extends PrintTransport {
  const _NoopPrintTransport();

  @override
  Future<List<PrinterEndpoint>> discover() async => const [];

  @override
  Future<PrintTransportResult> printJob({
    required PrintJob job,
    required PrinterEndpoint endpoint,
  }) async => const PrintTransportResult.success('printed');

  @override
  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async =>
      const PrintTransportResult.success('printed');

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) async =>
      const PrintTransportStatus(isAvailable: true, message: 'ready');
}
