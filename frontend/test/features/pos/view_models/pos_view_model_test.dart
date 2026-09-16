import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/core/analytics_engine.dart';
import 'package:pointy_frontend/src/core/storage/app_key_value_store.dart';
import 'package:pointy_frontend/src/core/storage/local_database.dart';
import 'package:pointy_frontend/src/core/storage/sqlite_key_value_store.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/analytics_event.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/print_job.dart';
import 'package:pointy_frontend/src/data/models/modifier_group.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_unit.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/shared/barcode/scale_barcode.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/query.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/repositories/analytics_repository.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/analytics_queue_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/unit_of_measure_api_client.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pointy_frontend/src/shared/barcode/scan_feedback_sounds.dart';
import 'package:pointy_frontend/src/shared/unit_options.dart';

void main() {
  _registerTillBlindSpotTests();
  _registerAutoPrintFloorTests();
  test(
    'cart totals update and checkout locks mutations until success',
    () async {
      final checkoutCompleter = Completer<SaleOrder>();
      final apiService = _FakePosApiService(
        checkoutCompleter: checkoutCompleter,
        catalogPages: const {
          1: [_coffeeVariant, _teaVariant],
        },
      );
      final viewModel = _viewModel(apiService);
      addTearDown(viewModel.dispose);

      await viewModel.loadCurrentRegisterSession();
      expect(viewModel.availableRegisterSession, isNotNull);
      await viewModel.resumeRegisterSession();
      expect(viewModel.activeRegisterSession, isNotNull);

      viewModel.addVariant(_coffeeVariant);
      viewModel.addVariant(_coffeeVariant);

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
      expect(apiService.capturedCheckoutDraft?.lines.single.variantId, 101);
      expect(apiService.capturedCheckoutDraft?.lines.single.quantity, 2);
      expect(apiService.capturedCheckoutDraft?.payments.single.amount, 7);

      viewModel.addVariant(_teaVariant);
      viewModel.decrementVariant(_coffeeVariant);
      viewModel.clearCart();

      expect(viewModel.cart, hasLength(1));
      expect(viewModel.cart.single.variant.id, 101);
      expect(viewModel.cart.single.quantity, 2);

      checkoutCompleter.complete(
        _saleOrder(
          total: 7,
          lines: const [
            SaleOrderLine(
              id: 10,
              productId: 101,
              variantId: 101,
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
      expect(viewModel.products.first.effectiveQuantityOnHand, 10);
    },
  );

  test('checkout retry reuses the active sale idempotency key', () async {
    var attempts = 0;
    final keys = <String?>[];
    final apiService = _FakePosApiService(
      onCheckout: (draft, idempotencyKey) async {
        keys.add(idempotencyKey);
        attempts += 1;
        if (attempts == 1) {
          throw Exception('offline');
        }
        return _saleOrder(total: draft.payments.single.amount, lines: const []);
      },
    );
    final viewModel = _viewModel(apiService);
    addTearDown(viewModel.dispose);

    await viewModel.loadCurrentRegisterSession();
    await viewModel.resumeRegisterSession();
    viewModel.addVariant(_coffeeVariant);
    await _settle();

    final failedOutcome = await viewModel.checkoutCurrentSale(
      payments: const [
        SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 3.5),
      ],
    );
    final retriedOutcome = await viewModel.checkoutCurrentSale(
      payments: const [
        SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 3.5),
      ],
    );

    expect(failedOutcome.isSuccess, isFalse);
    expect(retriedOutcome.isSuccess, isTrue);
    expect(keys, hasLength(2));
    expect(keys.first, isNotNull);
    expect(keys.first, keys.last);
    expect(keys.first, startsWith('checkout:'));
    await _settle();
  });

  test('a line note keeps the line separate from plain re-adds', () async {
    final apiService = _FakePosApiService(
      catalogPages: const {
        1: [_coffeeVariant],
      },
    );
    final viewModel = _viewModel(apiService);
    addTearDown(viewModel.dispose);

    await viewModel.loadCurrentRegisterSession();
    await viewModel.resumeRegisterSession();

    viewModel.addVariant(_coffeeVariant);
    final notedKey = viewModel.cart.single.lineKey;
    viewModel.setCartLineNote(notedKey, 'بدون سكر');
    // A fresh add of the same variant must not merge into the noted line.
    viewModel.addVariant(_coffeeVariant);
    await _settle();

    expect(viewModel.cart, hasLength(2));
    final noted = viewModel.cart.firstWhere((line) => line.lineKey == notedKey);
    expect(noted.notes, 'بدون سكر');
    expect(noted.quantity, 1);
    final plain = viewModel.cart.firstWhere((line) => line.lineKey != notedKey);
    expect(plain.notes, isEmpty);
    expect(plain.quantity, 1);

    // Per-line mutations target the line by key, not the variant.
    viewModel.removeCartLine(notedKey);
    expect(viewModel.cart, hasLength(1));
    expect(viewModel.cart.single.lineKey, plain.lineKey);
    await _settle();
  });

  test('checkout sends the per-line kitchen note', () async {
    final apiService = _FakePosApiService(
      catalogPages: const {
        1: [_coffeeVariant],
      },
    );
    final viewModel = _viewModel(apiService);
    addTearDown(viewModel.dispose);

    await viewModel.loadCurrentRegisterSession();
    await viewModel.resumeRegisterSession();

    viewModel.addVariant(_coffeeVariant);
    viewModel.setCartLineNote(viewModel.cart.single.lineKey, 'ساخن جدًا');
    await _settle();

    await viewModel.checkoutCurrentSale(
      payments: const [
        SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 3.5),
      ],
    );
    await _settle();

    expect(apiService.capturedCheckoutDraft?.lines.single.notes, 'ساخن جدًا');
  });

  test('modifier selection prices the line and gates merging', () async {
    final apiService = _FakePosApiService(
      catalogPages: const {
        1: [_coffeeVariant],
      },
    );
    final viewModel = _viewModel(apiService);
    addTearDown(viewModel.dispose);

    await viewModel.loadCurrentRegisterSession();
    await viewModel.resumeRegisterSession();

    const oat = CartLineModifier(
      groupId: 1,
      optionId: 10,
      groupName: 'Milk',
      optionName: 'Oat',
      priceDelta: 0.5,
      quantity: 1,
    );
    const whole = CartLineModifier(
      groupId: 1,
      optionId: 11,
      groupName: 'Milk',
      optionName: 'Whole',
      priceDelta: 0,
      quantity: 1,
    );

    viewModel.addVariant(_coffeeVariant, modifiers: const [oat]);
    viewModel.addVariant(_coffeeVariant, modifiers: const [whole]);
    // Different modifier choices stay as separate lines.
    expect(viewModel.cart, hasLength(2));

    // An identical selection merges into the existing line.
    viewModel.addVariant(_coffeeVariant, modifiers: const [oat]);
    expect(viewModel.cart, hasLength(2));
    final oatLine = viewModel.cart.firstWhere(
      (line) => line.modifiers.any((modifier) => modifier.optionId == 10),
    );
    expect(oatLine.quantity, 2);
    // (3.50 base + 0.50 oat) × 2 = 8.00.
    expect(oatLine.subtotal, 8.0);
    await _settle();
  });

  test('checkout sends the selected modifiers on the line', () async {
    final apiService = _FakePosApiService(
      catalogPages: const {
        1: [_coffeeVariant],
      },
    );
    final viewModel = _viewModel(apiService);
    addTearDown(viewModel.dispose);

    await viewModel.loadCurrentRegisterSession();
    await viewModel.resumeRegisterSession();

    viewModel.addVariant(
      _coffeeVariant,
      modifiers: const [
        CartLineModifier(
          groupId: 2,
          optionId: 20,
          groupName: 'Extras',
          optionName: 'Extra shot',
          priceDelta: 0.5,
          quantity: 2,
        ),
      ],
    );
    await _settle();

    await viewModel.checkoutCurrentSale(
      payments: const [
        SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 4.5),
      ],
    );
    await _settle();

    final line = apiService.capturedCheckoutDraft?.lines.single;
    expect(line?.modifiers.single.optionId, 20);
    expect(line?.modifiers.single.quantity, 2);
  });

  test('checkout retry rotates idempotency key when payment changes', () async {
    final keys = <String?>[];
    final apiService = _FakePosApiService(
      onCheckout: (draft, idempotencyKey) async {
        keys.add(idempotencyKey);
        throw Exception('offline');
      },
    );
    final viewModel = _viewModel(apiService);
    addTearDown(viewModel.dispose);

    await viewModel.loadCurrentRegisterSession();
    await viewModel.resumeRegisterSession();
    viewModel.addVariant(_coffeeVariant);
    await _settle();

    await viewModel.checkoutCurrentSale(
      payments: const [
        SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 3.5),
      ],
    );
    await viewModel.checkoutCurrentSale(
      payments: const [
        SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 3.5),
      ],
    );
    await viewModel.checkoutCurrentSale(
      payments: const [
        SaleCheckoutPaymentDraft(method: PaymentMethod.card, amount: 3.5),
      ],
    );

    expect(keys, hasLength(3));
    expect(keys[0], keys[1]);
    expect(keys[2], isNot(keys[0]));
    await _settle();
  });

  test(
    'search resets catalog pagination and load more appends results',
    () async {
      final apiService = _FakePosApiService(
        onFetchProducts: (query, page) {
          if (query.search == 'قهوة' && page == 1) {
            return ProductPage(
              products: [Product.fromVariant(_coffeeVariant)],
              hasMore: true,
            );
          }
          if (query.search == 'قهوة' && page == 2) {
            return ProductPage(
              products: [Product.fromVariant(_coffeeBeansVariant)],
              hasMore: false,
            );
          }
          return ProductPage(
            products: [Product.fromVariant(_teaVariant)],
            hasMore: false,
          );
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

  test(
    'product selection adds a single variant or asks for a variant',
    () async {
      final apiService = _FakePosApiService();
      final viewModel = _viewModel(apiService);
      addTearDown(viewModel.dispose);

      final singleResult = await viewModel.selectProductForSale(
        Product.fromVariant(_coffeeVariant),
      );

      expect(singleResult.status, PosProductSelectionStatus.added);
      expect(viewModel.cart.single.variant.id, _coffeeVariant.id);

      final multiVariantProduct = Product(
        id: 4,
        name: 'قميص',
        quantityOnHand: 7,
        defaultVariant: _shirtRedLargeVariant,
        variants: const [_shirtRedLargeVariant, _shirtBlueMediumVariant],
      );

      final multiResult = await viewModel.selectProductForSale(
        multiVariantProduct,
      );

      expect(multiResult.status, PosProductSelectionStatus.chooseVariant);
      expect(multiResult.variants.map((variant) => variant.id), [201, 202]);
      expect(viewModel.cart, hasLength(1));

      await _settle();
    },
  );

  test(
    'catalog-tapped variant without embedded product_detail still resolves its '
    'sale units from the parent product',
    () async {
      final viewModel = _viewModel(_FakePosApiService());
      addTearDown(viewModel.dispose);

      // The slim catalog payload no longer embeds product_detail on a product's
      // nested variants (the parent product already carries the units/modifiers).
      // POS must re-attach the product so a cart line built from the variant can
      // still resolve them via Product.fromVariant.
      const bareVariant = ProductVariant(
        id: 501,
        productId: 50,
        productName: 'شاي',
        displayName: 'شاي',
        fullName: 'شاي',
        sku: 'TEA-1',
        unitPrice: 2,
        quantityOnHand: 40,
        isDefault: true,
        // productDetail intentionally omitted — as the slim payload now sends it.
      );
      const product = Product(
        id: 50,
        name: 'شاي',
        quantityOnHand: 40,
        defaultVariant: bareVariant,
        variants: [bareVariant],
        units: [
          ProductUnit(
            unit: UnitOfMeasure(id: 20, code: 'carton', name: 'كرتون'),
            factorToBase: 12,
          ),
        ],
      );

      final result = await viewModel.selectProductForSale(product);

      expect(result.status, PosProductSelectionStatus.added);
      final line = viewModel.cart.single;
      // The bare variant picked up the parent product's context...
      expect(line.variant.productDetail, isNotNull);
      // ...so the cart line's unit switcher still sees the carton unit.
      expect(Product.fromVariant(line.variant).hasSellableUnits, isTrue);

      await _settle();
    },
  );

  test('re-adding an existing cart line keeps its position', () async {
    final viewModel = _viewModel(_FakePosApiService());
    addTearDown(viewModel.dispose);

    viewModel.addVariant(_coffeeVariant);
    viewModel.addVariant(_teaVariant);
    // A repeat add (or any quantity change) merges IN PLACE — the list order
    // is fixed at first insertion so lines never jump under the cashier.
    viewModel.addVariant(_coffeeVariant);

    expect(viewModel.cart.map((line) => line.variant.id), [
      _coffeeVariant.id,
      _teaVariant.id,
    ]);
    expect(viewModel.cart.first.quantity, 2);
    await _settle();
  });

  test('checkout of a quick invoice returns to the parked invoice', () async {
    final apiService = _FakePosApiService();
    final viewModel = _viewModel(apiService);
    addTearDown(viewModel.dispose);

    await viewModel.loadCurrentRegisterSession();
    await viewModel.resumeRegisterSession();

    viewModel.addVariant(_coffeeVariant);

    expect(viewModel.activeSaleSessionNumber, 1);
    expect(viewModel.cart.single.variant.id, _coffeeVariant.id);
    expect(viewModel.saleSessions, hasLength(1));

    viewModel.startNewSaleSession();

    expect(viewModel.activeSaleSessionNumber, 2);
    expect(viewModel.cart, isEmpty);
    expect(viewModel.saleSessions, hasLength(2));

    viewModel.addVariant(_teaVariant);
    await _settle();

    final outcome = await viewModel.checkoutCurrentSale(
      payments: const [
        SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 2.75),
      ],
    );

    expect(outcome.isSuccess, isTrue);
    expect(apiService.capturedCheckoutDraft?.lines, hasLength(1));
    expect(apiService.capturedCheckoutDraft?.lines.single.variantId, 102);
    expect(viewModel.saleSessions, hasLength(1));
    expect(viewModel.activeSaleSessionNumber, 1);
    expect(viewModel.cart.single.variant.id, _coffeeVariant.id);
    expect(viewModel.cart.single.quantity, 1);
    await _settle();
  });

  test('switching invoices preserves coupon and lines', () async {
    final apiService = _FakePosApiService();
    final viewModel = _viewModel(apiService);
    addTearDown(viewModel.dispose);

    await viewModel.loadCurrentRegisterSession();
    await viewModel.resumeRegisterSession();

    viewModel.addVariant(_coffeeVariant);
    viewModel.updateCouponCode('SAVE');
    viewModel.startNewSaleSession();
    viewModel.addVariant(_teaVariant);
    await _settle();

    expect(viewModel.activeSaleSessionNumber, 2);
    expect(viewModel.couponCode, isEmpty);
    expect(viewModel.cart.single.variant.id, _teaVariant.id);

    final parkedSession = viewModel.saleSessions.firstWhere(
      (session) => !session.isActive,
    );
    viewModel.switchSaleSession(parkedSession.id);

    expect(viewModel.activeSaleSessionNumber, 1);
    expect(viewModel.couponCode, 'SAVE');
    expect(viewModel.cart.single.variant.id, _coffeeVariant.id);
    await _settle();
  });

  test(
    'cart audit tracking captures item, source, and cart snapshots',
    () async {
      final sink = _FakeAnalyticsSink();
      final engine = AnalyticsEngine(
        sink,
        storage: MemoryAnalyticsQueueStorage(installationId: 'pos-audit-test'),
        flushInterval: const Duration(hours: 1),
        maxBatchSize: 100,
      );
      await engine.start();
      engine.setCurrentUser(1); // authenticated: flush is allowed to POST
      sink.acceptedEvents.clear();

      final viewModel = _viewModel(
        _FakePosApiService(),
        analyticsEngine: engine,
      );
      addTearDown(viewModel.dispose);
      addTearDown(engine.dispose);

      await viewModel.loadCurrentRegisterSession();
      await viewModel.resumeRegisterSession();

      viewModel.addVariant(_coffeeVariant, source: 'product_tile');
      await _settle();
      viewModel.addVariant(_coffeeVariant, source: 'cart_quantity_button');
      await _settle();
      viewModel.decrementVariant(
        _coffeeVariant,
        source: 'cart_quantity_button',
      );
      await _settle();
      viewModel.clearCart(source: 'cart_clear_button');
      await _settle();
      await engine.flush();

      final events = sink.acceptedEvents
          .where((event) => event.name.startsWith('pos.cart.'))
          .toList();
      expect(events.map((event) => event.name), [
        'pos.cart.line.added',
        'pos.cart.line.quantity_increased',
        'pos.cart.line.quantity_decreased',
        'pos.cart.line.deleted',
        'pos.cart.cleared',
      ]);

      final added = events.first;
      expect(added.eventType, AnalyticsEventType.audit);
      expect(added.entityType, 'cart_line');
      expect(added.entityId, '${_coffeeVariant.id}');
      expect(added.sessionId, 'register:${_openSession.id}');
      expect(added.attributes['source'], 'product_tile');
      expect(added.attributes['product_name'], _coffeeVariant.productName);
      expect(added.attributes['variant_id'], _coffeeVariant.id);
      expect(added.metrics['quantity'], 1);
      expect(added.metrics['cart_total'], _coffeeVariant.unitPrice);

      final increased = events[1];
      expect(increased.name, 'pos.cart.line.quantity_increased');
      expect(increased.attributes['previous_quantity'], 1);
      expect(increased.attributes['new_quantity'], 2);
      expect(increased.metrics['cart_item_count'], 2);

      final deleted = events[3];
      expect(deleted.name, 'pos.cart.line.deleted');
      expect(deleted.attributes['reason'], 'clear_cart');
      expect(deleted.attributes['source'], 'cart_clear_button');

      final cleared = events.last;
      expect(cleared.entityType, 'cart');
      expect(cleared.attributes['source'], 'cart_clear_button');
      expect(cleared.metrics['line_count'], 1);
      expect(cleared.metrics['item_count'], 1);
      final clearedLines = cleared.attributes['lines'] as List<Object?>;
      expect(clearedLines, hasLength(1));
      expect(
        (clearedLines.single! as Map<String, Object?>)['product_name'],
        _coffeeVariant.productName,
      );
    },
  );

  test('a cart line round-trips through json persistence', () {
    final line = CartLine.create(
      variant: _coffeeVariant,
      quantity: 3,
      notes: 'no sugar',
      modifiers: const [
        CartLineModifier(
          groupId: 7,
          optionId: 9,
          groupName: 'Milk',
          optionName: 'Oat',
          priceDelta: 0.5,
          quantity: 2,
        ),
      ],
      unitCode: 'box',
      unitLabel: 'Box',
      unitFactor: 12,
      unitPriceOverride: 40,
    );

    final restored = CartLine.fromJson(
      (jsonDecode(jsonEncode(line.toJson())) as Map).cast<String, Object?>(),
    );

    expect(restored.variant.id, _coffeeVariant.id);
    expect(restored.variant.productName, _coffeeVariant.productName);
    expect(restored.variant.unitPrice, _coffeeVariant.unitPrice);
    expect(restored.quantity, 3);
    expect(restored.notes, 'no sugar');
    expect(restored.unitCode, 'box');
    expect(restored.unitFactor, 12);
    expect(restored.unitPriceOverride, 40);
    expect(restored.lineKey, line.lineKey);
    expect(restored.modifiers, hasLength(1));
    expect(restored.modifiers.single.optionName, 'Oat');
    expect(restored.modifiers.single.priceDelta, 0.5);
    expect(restored.modifiers.single.quantity, 2);
    // 40 (override) + 0.5 * 2 (modifier) = 41
    expect(restored.unitPrice, 41);
  });

  test(
    'an in-progress cart is persisted and restored for the same user',
    () async {
      final storage = MemoryScopedJsonStorage();
      final first = _viewModel(
        _FakePosApiService(
          catalogPages: const {
            1: [_coffeeVariant, _teaVariant],
          },
        ),
        sessionStorage: storage,
      );
      addTearDown(first.dispose);
      await first.loadCurrentRegisterSession();
      await first.resumeRegisterSession();
      await first.restorePersistedSessions('user-1');

      first.addVariant(_coffeeVariant);
      first.addVariant(_coffeeVariant);
      expect(first.cart, hasLength(1));

      // Let the debounced save flush to storage.
      await Future<void>.delayed(const Duration(milliseconds: 700));

      final second = _viewModel(
        _FakePosApiService(
          catalogPages: const {
            1: [_coffeeVariant, _teaVariant],
          },
        ),
        sessionStorage: storage,
      );
      addTearDown(second.dispose);
      await second.restorePersistedSessions('user-1');

      expect(second.cart, hasLength(1));
      expect(second.cart.single.variant.id, _coffeeVariant.id);
      expect(second.cart.single.quantity, 2);

      // A different user on the same device never inherits the cart.
      final third = _viewModel(
        _FakePosApiService(catalogPages: const {}),
        sessionStorage: storage,
      );
      addTearDown(third.dispose);
      await third.restorePersistedSessions('user-2');
      expect(third.cart, isEmpty);
    },
  );

  group('active cart line (scan / tap shortcuts)', () {
    test('a hardware scan marks the line it landed on as the active line', () async {
      final viewModel = _viewModel(
        _FakePosApiService(
          catalogPages: const {
            1: [_coffeeVariant],
          },
        ),
      );
      addTearDown(viewModel.dispose);

      await viewModel.addVariantByBarcode('1000001');
      expect(viewModel.cart.single.quantity, 1);
      expect(viewModel.activeCartLine, isNotNull);
      expect(viewModel.activeCartLine!.variant.id, _coffeeVariant.id);
    });

    test('scanning only ever adds its own product — it never touches another '
        "line's quantity", () async {
      final viewModel = _viewModel(
        _FakePosApiService(
          catalogPages: const {
            1: [_coffeeVariant, _eggVariant],
          },
        ),
      );
      addTearDown(viewModel.dispose);

      // Scan coffee twice: its own line increments, as expected.
      await viewModel.addVariantByBarcode('1000001');
      await viewModel.addVariantByBarcode('1000001');
      expect(
        viewModel.cart
            .firstWhere((line) => line.variant.id == _coffeeVariant.id)
            .quantity,
        2,
      );

      // Scanning a different product adds it at quantity 1 and leaves the
      // coffee line exactly where it was — a scan can never overwrite a
      // quantity the way the old scan-then-type flow could.
      await viewModel.addVariantByBarcode('4000001');
      expect(
        viewModel.cart
            .firstWhere((line) => line.variant.id == _coffeeVariant.id)
            .quantity,
        2,
      );
      expect(
        viewModel.cart
            .firstWhere((line) => line.variant.id == _eggVariant.id)
            .quantity,
        1,
      );
    });

    test('a plain cart-button add does not mark an active line', () {
      final viewModel = _viewModel(_FakePosApiService());
      addTearDown(viewModel.dispose);

      viewModel.addVariant(_coffeeVariant);
      expect(viewModel.activeCartLine, isNull);
    });

    test('a catalog tile add marks the active line like a scan does', () {
      final viewModel = _viewModel(_FakePosApiService());
      addTearDown(viewModel.dispose);

      viewModel.addVariant(_coffeeVariant, source: 'product_tile');
      expect(viewModel.activeCartLine, isNotNull);
      expect(viewModel.activeCartLine!.variant.id, _coffeeVariant.id);
    });

    test('focusCartLine retargets the active line to a tapped line', () {
      final viewModel = _viewModel(_FakePosApiService());
      addTearDown(viewModel.dispose);

      viewModel.addVariant(_coffeeVariant, source: 'product_tile');
      viewModel.addVariant(_teaVariant, source: 'product_tile');
      // The most recent add (tea) is active; tapping the coffee line retargets.
      expect(viewModel.activeCartLine!.variant.id, _teaVariant.id);
      final coffeeLine = viewModel.cart.firstWhere(
        (line) => line.variant.id == _coffeeVariant.id,
      );
      viewModel.focusCartLine(coffeeLine.lineKey);
      expect(viewModel.activeCartLine!.variant.id, _coffeeVariant.id);
    });

    test('the active line clears once its line leaves the cart (F4 delete)',
        () async {
      final viewModel = _viewModel(
        _FakePosApiService(
          catalogPages: const {
            1: [_coffeeVariant],
          },
        ),
      );
      addTearDown(viewModel.dispose);

      await viewModel.addVariantByBarcode('1000001');
      final lineKey = viewModel.activeCartLine!.lineKey;
      viewModel.removeCartLine(lineKey, source: 'keyboard_delete_line');
      expect(viewModel.cart, isEmpty);
      expect(viewModel.activeCartLine, isNull);
    });

    test('scanning a packaging (unit) barcode rings up that unit', () async {
      final viewModel = _viewModel(
        _FakePosApiService(
          catalogPages: const {
            1: [_juiceVariant],
          },
        ),
      );
      addTearDown(viewModel.dispose);

      final added = await viewModel.addVariantByBarcode('3000002');
      expect(added, isTrue);
      final line = viewModel.cart.single;
      expect(line.variant.id, _juiceVariant.id);
      expect(line.quantity, 1);
      expect(line.unitCode, 'carton');
      expect(line.unitFactor, 24);
      // No custom carton price -> derived: 1.00 piece × 24.
      expect(line.unitPriceOverride, 24.0);
      // The scan marked the carton line as the active one (F2/F4 target).
      expect(viewModel.activeCartLine, isNotNull);
      expect(viewModel.activeCartLine!.unitCode, 'carton');
    });

    test('barcode scans chime by outcome: success then not-found', () async {
      final feedback = <ScanFeedback>[];
      final viewModel = _viewModel(
        _FakePosApiService(
          catalogPages: const {
            1: [_coffeeVariant],
          },
        ),
        scanFeedback: feedback.add,
      );
      addTearDown(viewModel.dispose);

      expect(await viewModel.addVariantByBarcode('1000001'), isTrue);
      expect(feedback, [ScanFeedback.success]);

      expect(await viewModel.addVariantByBarcode('5000009'), isFalse);
      expect(viewModel.barcodeScanStatus, BarcodeScanStatus.notFound);
      expect(feedback, [ScanFeedback.success, ScanFeedback.notFound]);
    });

    group('scale labels', () {
      const weightRule = ScaleBarcodeRule(
        pattern: '21IIIIIVVVVVC',
        name: 'produce',
      );
      const priceRule = ScaleBarcodeRule(
        pattern: '23IIIIIVVVVVC',
        valueKind: ScaleValueKind.price,
        valueDecimals: 2,
        name: 'deli',
      );

      PosViewModel scaleViewModel({
        List<ProductVariant> catalog = const [_tomatoVariant],
        List<ScaleBarcodeRule> rules = const [weightRule, priceRule],
        List<UnitOfMeasure>? units,
      }) {
        final viewModel = _viewModel(
          _FakePosApiService(
            catalogPages: {1: catalog},
            scaleRules: rules,
            unitsOfMeasure: units,
          ),
        );
        addTearDown(viewModel.dispose);
        return viewModel;
      }

      test('a weight label rings the weight it carries', () async {
        final viewModel = scaleViewModel();
        // 21 · 12345 · 01500 → 1.500 kg of the product stored as "12345".
        expect(await viewModel.addVariantByBarcode('2112345015002'), isTrue);

        final line = viewModel.cart.single;
        expect(line.variant.id, _tomatoVariant.id);
        expect(line.quantity, closeTo(1.5, 0.0001));
        expect(viewModel.lastScaleQuantity?.hasWarning, isFalse);
      });

      test('a price label rings the quantity that costs it', () async {
        final viewModel = scaleViewModel();
        // 23 · 12345 · 01250 → a 12.50 sticker on a 40.00/kg product.
        expect(await viewModel.addVariantByBarcode('2312345012500'), isTrue);

        final line = viewModel.cart.single;
        expect(line.quantity, closeTo(0.312, 0.0001));
        expect(viewModel.lastScaleQuantity?.labelTotal, closeTo(12.5, 0.0001));
        // Three decimals cannot land on 12.50 exactly, and the cashier is told.
        expect(viewModel.lastScaleQuantity?.warning, kScaleWarnRoundingDrift);
      });

      test('a counted product never takes a weight, and says so', () async {
        final viewModel = scaleViewModel(catalog: const [_breadVariant]);
        expect(await viewModel.addVariantByBarcode('2154321015002'), isTrue);

        expect(viewModel.cart.single.quantity, 1);
        expect(viewModel.lastScaleQuantity?.warning, kScaleWarnNotFractional);
      });

      test(
        'with no rules configured a label is just an unknown code',
        () async {
          final viewModel = scaleViewModel(rules: const []);
          expect(await viewModel.addVariantByBarcode('2112345015002'), isFalse);
          expect(viewModel.barcodeScanStatus, BarcodeScanStatus.notFound);
          expect(viewModel.lastScaleQuantity, isNull);
        },
      );

      test("a shop's own weight unit takes a weight like any other", () async {
        // Nothing about the code "wazna" says it is a weight; only the shop's
        // registry does. This is the case the built-in code list cannot answer.
        const wazna = ProductVariant(
          id: 110,
          productId: 10,
          productName: 'تمر',
          displayName: 'تمر',
          fullName: 'تمر',
          sku: 'DAT-001',
          unitPrice: 9,
          quantityOnHand: 30,
          barcode: '12345',
          unit: 'wazna',
          isDefault: true,
        );
        final viewModel = scaleViewModel(
          catalog: const [wazna],
          units: const [
            // The shop's own name for the kilogram: same dimension, same
            // reference factor, a code no built-in list could know.
            UnitOfMeasure(
              id: 1,
              code: 'wazna',
              name: 'وزنة',
              dimension: 'weight',
              referenceFactor: 1,
              allowsFractional: true,
            ),
            UnitOfMeasure(
              id: 2,
              code: 'kg',
              name: 'كيلوغرام',
              dimension: 'weight',
              referenceFactor: 1,
              allowsFractional: true,
            ),
          ],
        );

        expect(await viewModel.addVariantByBarcode('2112345015002'), isTrue);
        expect(viewModel.cart.single.quantity, closeTo(1.5, 0.0001));
        expect(viewModel.lastScaleQuantity?.hasWarning, isFalse);
      });

      test('an unreachable registry falls back to the built-in units', () async {
        // units: null — the registry cannot be read, and kilograms still work.
        final viewModel = scaleViewModel();
        expect(await viewModel.addVariantByBarcode('2112345015002'), isTrue);
        expect(viewModel.cart.single.quantity, closeTo(1.5, 0.0001));
      });

      test('an ordinary barcode carries no scale reading', () async {
        final viewModel = scaleViewModel(catalog: const [_coffeeVariant]);
        expect(await viewModel.addVariantByBarcode('1000001'), isTrue);
        expect(viewModel.lastScaleQuantity, isNull);
      });
    });

    test('a failed barcode lookup chimes the error sound', () async {
      final feedback = <ScanFeedback>[];
      final viewModel = _viewModel(
        _BarcodeErrorPosApiService(),
        scanFeedback: feedback.add,
      );
      addTearDown(viewModel.dispose);

      expect(await viewModel.addVariantByBarcode('1000001'), isFalse);
      expect(viewModel.barcodeScanStatus, BarcodeScanStatus.error);
      expect(feedback, [ScanFeedback.error]);
    });

    test('a swallowed rescan (mid-resolve) does not chime', () async {
      final feedback = <ScanFeedback>[];
      final viewModel = _viewModel(
        _FakePosApiService(
          catalogPages: const {
            1: [_coffeeVariant],
          },
        ),
        scanFeedback: feedback.add,
      );
      addTearDown(viewModel.dispose);

      final first = viewModel.addVariantByBarcode('1000001');
      // Fired while the first scan is still resolving: dropped silently.
      final second = viewModel.addVariantByBarcode('1000001');
      expect(await second, isFalse);
      expect(await first, isTrue);
      expect(feedback, [ScanFeedback.success]);
    });

    test('setActiveCartLineUnit switches the active line unit of measure',
        () async {
      final viewModel = _viewModel(
        _FakePosApiService(
          catalogPages: const {
            1: [_coffeeVariant],
          },
        ),
      );
      addTearDown(viewModel.dispose);

      await viewModel.addVariantByBarcode('1000001');
      const box = UnitOption(
        code: 'box',
        label: 'صندوق',
        unitPrice: 40,
        factorToBase: 12,
        allowsFractional: false,
        isBase: false,
      );
      expect(viewModel.setActiveCartLineUnit(box), isTrue);
      final line = viewModel.cart.single;
      expect(line.unitCode, 'box');
      expect(line.unitFactor, 12);
      expect(line.unitPriceOverride, 40);

      // Cycling back to the base unit clears the override.
      const base = UnitOption(
        code: 'piece',
        label: 'قطعة',
        unitPrice: 3.5,
        factorToBase: 1,
        allowsFractional: false,
        isBase: true,
      );
      expect(viewModel.setActiveCartLineUnit(base), isTrue);
      expect(viewModel.cart.single.unitCode, '');
      expect(viewModel.cart.single.unitPriceOverride, isNull);
    });
  });

  group('search focus signal (return-to-search workflow)', () {
    test('a catalog/scanner add asks for search focus', () {
      final viewModel = _viewModel(_FakePosApiService());
      addTearDown(viewModel.dispose);
      var requests = 0;
      viewModel.searchFocusController.addListener(() => requests += 1);

      viewModel.addVariant(_coffeeVariant, source: 'product_tile');
      expect(requests, 1);

      viewModel.addVariant(_teaVariant, source: 'variant_picker');
      expect(requests, 2);

      viewModel.addVariant(_coffeeVariant, source: 'camera_scanner');
      expect(requests, 3);
    });

    test('a plain cart-button add does not ask for search focus', () {
      final viewModel = _viewModel(_FakePosApiService());
      addTearDown(viewModel.dispose);
      var requests = 0;
      viewModel.searchFocusController.addListener(() => requests += 1);

      // The +/- buttons and other programmatic adds must not steal focus.
      viewModel.addVariant(_coffeeVariant);
      viewModel.incrementCartLine(viewModel.cart.single.lineKey);
      expect(requests, 0);
    });

    test('clearing the cart asks for search focus', () {
      final viewModel = _viewModel(_FakePosApiService());
      addTearDown(viewModel.dispose);
      viewModel.addVariant(_coffeeVariant);
      var requests = 0;
      viewModel.searchFocusController.addListener(() => requests += 1);

      viewModel.clearCart();
      expect(requests, 1);
    });

    test('opening and switching sale sessions asks for search focus', () {
      final viewModel = _viewModel(_FakePosApiService());
      addTearDown(viewModel.dispose);
      // A held sale is needed before a new session can be opened.
      viewModel.addVariant(_coffeeVariant);
      final firstSessionId = viewModel.activeSaleSessionSummary.id;
      var requests = 0;
      viewModel.searchFocusController.addListener(() => requests += 1);

      viewModel.startNewSaleSession();
      expect(requests, 1);

      viewModel.switchSaleSession(firstSessionId);
      expect(requests, 2);
    });

    test(
      'requestSearchFocus fires the controller (checkout / edit-done hook)',
      () {
        final viewModel = _viewModel(_FakePosApiService());
        addTearDown(viewModel.dispose);
        var requests = 0;
        viewModel.searchFocusController.addListener(() => requests += 1);

        viewModel.requestSearchFocus();
        expect(requests, 1);
      },
    );

    test('a hardware scan asks the search field to reset', () async {
      final viewModel = _viewModel(
        _FakePosApiService(
          catalogPages: const {
            1: [_coffeeVariant],
          },
        ),
      );
      addTearDown(viewModel.dispose);
      var resets = 0;
      viewModel.searchResetController.addListener(() => resets += 1);

      // A found scan clears the search field so the code can't linger there.
      expect(
        await viewModel.addVariantByBarcode(
          '1000001',
          source: 'hardware_scanner',
        ),
        isTrue,
      );
      expect(resets, 1);

      // It also fires when the scan misses — the field must clear either way.
      expect(
        await viewModel.addVariantByBarcode(
          '5000009',
          source: 'hardware_scanner',
        ),
        isFalse,
      );
      expect(resets, 2);

      // The manual "type a term + Enter" path (default source) must NOT reset —
      // it would wipe the cashier's typed search.
      await viewModel.addVariantByBarcode('1000001');
      expect(resets, 2);
    });
  });

  group('held-invoice cycling (Page Up / Page Down)', () {
    test('cycleActiveSaleSession walks the held invoices and wraps', () {
      final viewModel = _viewModel(_FakePosApiService());
      addTearDown(viewModel.dispose);

      // A single open invoice: nothing to cycle, so the key isn't consumed.
      expect(viewModel.cycleActiveSaleSession(forward: true), isFalse);

      // Open three invoices (each new one needs a non-empty active cart).
      viewModel.addVariant(_coffeeVariant);
      viewModel.startNewSaleSession();
      viewModel.addVariant(_teaVariant);
      viewModel.startNewSaleSession();
      expect(viewModel.saleSessions, hasLength(3));
      expect(viewModel.activeSaleSessionNumber, 3);

      // Page Down (forward) wraps from the last invoice back to the first.
      expect(viewModel.cycleActiveSaleSession(forward: true), isTrue);
      expect(viewModel.activeSaleSessionNumber, 1);
      expect(viewModel.cycleActiveSaleSession(forward: true), isTrue);
      expect(viewModel.activeSaleSessionNumber, 2);

      // Page Up (backward) wraps from the first invoice to the last.
      expect(viewModel.cycleActiveSaleSession(forward: false), isTrue);
      expect(viewModel.activeSaleSessionNumber, 1);
      expect(viewModel.cycleActiveSaleSession(forward: false), isTrue);
      expect(viewModel.activeSaleSessionNumber, 3);
    });
  });

  group('discount preview gate', () {
    test('a no-rules preview latches: later cart edits preview locally, '
        'with zero requests', () async {
      final apiService = _FakePosApiService(
        discountsVersion: '7',
        onPreviewDiscounts: (draft) async => const SaleDiscountPreview(
          subtotal: 3.5,
          discountTotal: 0,
          total: 3.5,
          rulesActive: false,
          rulesVersion: '7',
        ),
      );
      final viewModel = _viewModel(apiService);
      addTearDown(viewModel.dispose);
      await viewModel.loadCurrentRegisterSession();
      await viewModel.resumeRegisterSession();

      viewModel.addVariant(_coffeeVariant);
      await _settle();
      expect(apiService.previewRequests, 1, reason: 'first preview is live');
      expect(viewModel.discountRulesKnownInactive, isTrue);

      viewModel.addVariant(_coffeeVariant);
      await _settle();
      expect(apiService.previewRequests, 1, reason: 'latched: no request');
      expect(viewModel.hasDiscountPreviewError, isFalse);
      expect(viewModel.total, viewModel.subtotal);
      expect(viewModel.discountTotal, 0);
    });

    test('after the latch, a failing server preview degrades to local totals '
        'instead of an error', () async {
      var failing = false;
      final apiService = _FakePosApiService(
        discountsVersion: '7',
        onPreviewDiscounts: (draft) async {
          if (failing) {
            throw Exception('network down');
          }
          return const SaleDiscountPreview(
            subtotal: 3.5,
            discountTotal: 0,
            total: 3.5,
            rulesActive: false,
            rulesVersion: '7',
          );
        },
      );
      final viewModel = _viewModel(apiService);
      addTearDown(viewModel.dispose);
      await viewModel.loadCurrentRegisterSession();
      await viewModel.resumeRegisterSession();

      viewModel.addVariant(_coffeeVariant);
      await _settle();
      expect(viewModel.discountRulesKnownInactive, isTrue);

      failing = true;
      await viewModel.refreshDiscountPreview(forceServer: true);
      expect(viewModel.hasDiscountPreviewError, isFalse,
          reason: 'no coupon + no rules: nothing depends on the server');
      expect(viewModel.total, viewModel.subtotal);
    });

    test('active rules clear the latch and previews stay live', () async {
      final apiService = _FakePosApiService(
        discountsVersion: '7',
        onPreviewDiscounts: (draft) async => const SaleDiscountPreview(
          subtotal: 3.5,
          discountTotal: 0.5,
          total: 3.0,
          rulesActive: true,
          rulesVersion: '7',
        ),
      );
      final viewModel = _viewModel(apiService);
      addTearDown(viewModel.dispose);
      await viewModel.loadCurrentRegisterSession();
      await viewModel.resumeRegisterSession();

      viewModel.addVariant(_coffeeVariant);
      await _settle();
      expect(viewModel.discountRulesKnownInactive, isFalse);

      viewModel.addVariant(_coffeeVariant);
      await _settle();
      expect(apiService.previewRequests, 2, reason: 'rules active: stay live');
    });

    test('a failure with no latch still reports the preview error', () async {
      final apiService = _FakePosApiService(
        discountsVersion: '7',
        onPreviewDiscounts: (draft) async => throw Exception('network down'),
      );
      final viewModel = _viewModel(apiService);
      addTearDown(viewModel.dispose);
      await viewModel.loadCurrentRegisterSession();
      await viewModel.resumeRegisterSession();

      viewModel.addVariant(_coffeeVariant);
      await _settle();
      expect(viewModel.hasDiscountPreviewError, isTrue,
          reason: 'rules unknown: the error must surface');
    });
  });

  group('checkout survives a broken receipt printer', () {
    test('a printer that hangs never freezes the committed sale', () async {
      // The printer accepts the job but never finishes (out of paper / wedged
      // spooler): its Future never completes. Before the fix this hung checkout
      // forever with `isCheckingOut` stuck true; now the print step is abandoned
      // at the deadline and the sale still finalizes cleanly.
      final apiService = _FakePosApiService(
        shopSettings: _autoPrintSettings,
        catalogPages: const {
          1: [_coffeeVariant],
        },
      );
      final stubPrinting = _StubPrintingRepository(
        apiService,
        invoiceResult: () => Completer<PrintTransportResult>().future,
      );
      final viewModel = _viewModel(
        apiService,
        printingRepository: stubPrinting,
        checkoutPrintDeadline: const Duration(milliseconds: 50),
      );
      addTearDown(viewModel.dispose);

      await viewModel.loadCurrentRegisterSession();
      await viewModel.resumeRegisterSession();
      await viewModel.loadCheckoutSettings();
      viewModel.addVariant(_coffeeVariant);

      final outcome = await viewModel
          .checkoutCurrentSale(
            payments: const [
              SaleCheckoutPaymentDraft(
                method: PaymentMethod.cash,
                amount: 3.5,
              ),
            ],
          )
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () =>
                fail('checkout hung on the stalled printer — the bug is back'),
          );

      expect(stubPrinting.invoiceCalls, 1, reason: 'the print was attempted');
      expect(outcome.isSuccess, isTrue, reason: 'the sale is committed');
      expect(
        outcome.printStatus,
        InvoicePrintStatus.failed,
        reason: 'the stalled print surfaces as a failed receipt, not a hang',
      );
      expect(viewModel.isCheckingOut, isFalse, reason: 'the POS is unlocked');
      expect(viewModel.cart, isEmpty, reason: 'the sale finalized');
    });

    test('the print budget is shared across steps, not per step', () async {
      // Two post-sale print steps (invoice + kitchen chits) both behind a
      // stalled printer must not each get the full deadline and sum to ~2x the
      // freeze. The invoice hangs and exhausts the ONE shared budget, so the
      // kitchen step is abandoned immediately instead of hanging for another
      // full deadline (the ~40s checkout tail seen in the field).
      final apiService = _FakePosApiService(
        shopSettings: _autoPrintSettings,
        catalogPages: const {
          1: [_coffeeVariant],
        },
        onCheckout: (draft, key) async => _saleOrder(
          total: 3.5,
          lines: const [],
          kitchenPrintJobs: const [
            PrintJob(
              id: 1,
              status: PrintJobStatus.pending,
              jobType: 'kitchen_ticket',
              payload: {},
            ),
          ],
        ),
      );
      final stubPrinting = _StubPrintingRepository(
        apiService,
        invoiceResult: () => Completer<PrintTransportResult>().future,
      );
      final viewModel = _viewModel(
        apiService,
        printingRepository: stubPrinting,
        checkoutPrintDeadline: const Duration(milliseconds: 50),
      );
      addTearDown(viewModel.dispose);

      await viewModel.loadCurrentRegisterSession();
      await viewModel.resumeRegisterSession();
      await viewModel.loadCheckoutSettings();
      viewModel.addVariant(_coffeeVariant);

      final outcome = await viewModel
          .checkoutCurrentSale(
            payments: const [
              SaleCheckoutPaymentDraft(
                method: PaymentMethod.cash,
                amount: 3.5,
              ),
            ],
          )
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () =>
                fail('checkout hung — the shared print budget regressed'),
          );

      expect(stubPrinting.invoiceCalls, 1, reason: 'the invoice was attempted');
      expect(
        stubPrinting.kitchenConfigLoads,
        0,
        reason: 'the invoice hang exhausted the shared budget, so the kitchen '
            'step is skipped rather than granted its own full deadline',
      );
      expect(outcome.isSuccess, isTrue, reason: 'the sale is committed');
      expect(viewModel.isCheckingOut, isFalse, reason: 'the POS is unlocked');
    });

    test('a printer that throws is swallowed, not propagated', () async {
      // A thrown transport/encoder error must become a failed receipt, never an
      // uncaught exception bubbling out of checkout.
      final apiService = _FakePosApiService(
        shopSettings: _autoPrintSettings,
        catalogPages: const {
          1: [_coffeeVariant],
        },
      );
      final stubPrinting = _StubPrintingRepository(
        apiService,
        invoiceResult: () async => throw Exception('printer exploded'),
      );
      final viewModel = _viewModel(
        apiService,
        printingRepository: stubPrinting,
      );
      addTearDown(viewModel.dispose);

      await viewModel.loadCurrentRegisterSession();
      await viewModel.resumeRegisterSession();
      await viewModel.loadCheckoutSettings();
      viewModel.addVariant(_coffeeVariant);

      final outcome = await viewModel.checkoutCurrentSale(
        payments: const [
          SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 3.5),
        ],
      );

      expect(outcome.isSuccess, isTrue);
      expect(outcome.printStatus, InvoicePrintStatus.failed);
      expect(viewModel.isCheckingOut, isFalse);
      expect(viewModel.cart, isEmpty);
    });
  });
  test('closing the till inside the debounce window still saves', () async {
    final storage = _SlowScopedJsonStorage();
    final vm = _viewModel(
      _FakePosApiService(
        catalogPages: const {
          1: [_coffeeVariant],
        },
      ),
      sessionStorage: storage,
    );
    await vm.restorePersistedSessions('user-1');
    vm.addVariant(_coffeeVariant);

    // The app is closed (or Android kills it) a few milliseconds later, well
    // inside the 500ms the debounced write was waiting out.
    vm.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      storage.peek('user-1'),
      isNotNull,
      reason: 'the last thing the cashier scanned was never written',
    );
  });

  test(
    'the open invoices really survive a power cut, through the SQLite file',
    () async {
      // End to end over the production storage class and a real
      // `pointy_store.db`, closed and reopened in between — the memory double
      // the other tests use cannot show that the bytes reached the disk.
      sqfliteFfiInit();
      final tempDir = Directory.systemTemp.createTempSync('pos_sessions_db');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final path = '${tempDir.path}${Platform.pathSeparator}pointy_store.db';
      Future<LocalDatabase> openStore() => LocalDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
        schema: const <String>[SqliteKeyValueStore.schema],
      );

      var database = await openStore();
      AppKeyValueStore.debugOverride(SqliteKeyValueStore(database));
      addTearDown(AppKeyValueStore.reset);

      const storage = SharedPreferencesScopedJsonStorage(
        'pointy.pos.sessions.v1',
      );
      final api = _FakePosApiService(
        catalogPages: const {
          1: [_coffeeVariant, _teaVariant],
        },
      );

      // Cashier 7 is mid-shift: one invoice open, one held behind it.
      final before = _viewModel(api, sessionStorage: storage);
      addTearDown(before.dispose);
      await before.loadCurrentRegisterSession();
      await before.resumeRegisterSession();
      await before.restorePersistedSessions('7');
      before.addVariant(_coffeeVariant);
      before.startNewSaleSession();
      before.addVariant(_teaVariant);
      before.addVariant(_teaVariant);
      await Future<void>.delayed(const Duration(milliseconds: 700));

      // The mains go. Anything not committed to the file is gone with them.
      await database.close();
      database = await openStore();
      AppKeyValueStore.debugOverride(SqliteKeyValueStore(database));
      addTearDown(() async => database.close());

      // Cashier 8 signs in on the same till first, and sees their own nothing.
      final other = _viewModel(api, sessionStorage: storage);
      addTearDown(other.dispose);
      await other.restorePersistedSessions('8');
      await _settle();
      expect(other.cart, isEmpty);
      expect(other.openSaleSessionCount, 1);

      // Then cashier 7 comes back: sign in, then tap "continue selling".
      final after = _viewModel(api, sessionStorage: storage);
      addTearDown(after.dispose);
      await after.loadCurrentRegisterSession();
      await after.restorePersistedSessions('7');
      await _settle();
      await after.resumeRegisterSession();

      expect(after.openSaleSessionCount, 2);
      final restored = <int, double>{};
      for (final session in after.saleSessions) {
        after.switchSaleSession(session.id);
        for (final line in after.cart) {
          restored[line.variant.id] = line.quantity;
        }
      }
      expect(restored, {_coffeeVariant.id: 1.0, _teaVariant.id: 2.0});

      // And it is on the disk under this cashier's own key, and only theirs.
      final keys = await SqliteKeyValueStore(database).getKeys();
      expect(keys, contains('pointy.pos.sessions.v1.7'));
      expect(keys, isNot(contains('pointy.pos.sessions.v1.8')));
    },
  );

  test(
    'resuming the open drawer keeps the invoices the power cut interrupted',
    () async {
      final storage = _SlowScopedJsonStorage();
      final api = _FakePosApiService(
        catalogPages: const {
          1: [_coffeeVariant, _teaVariant],
        },
      );

      // Mid-shift: one invoice being rung up and one held behind it.
      final before = _viewModel(api, sessionStorage: storage);
      addTearDown(before.dispose);
      await before.loadCurrentRegisterSession();
      await before.resumeRegisterSession();
      await before.restorePersistedSessions('user-1');
      before.addVariant(_coffeeVariant);
      before.startNewSaleSession();
      before.addVariant(_teaVariant);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(before.openSaleSessionCount, 2);

      // The power comes back. Sign-in reads the open drawer and the snapshot,
      // in that order, and then the cashier taps "متابعة البيع" on the gate.
      final after = _viewModel(api, sessionStorage: storage);
      addTearDown(after.dispose);
      await after.loadCurrentRegisterSession();
      await after.restorePersistedSessions('user-1');
      expect(after.openSaleSessionCount, 2);

      await after.resumeRegisterSession();

      expect(
        after.openSaleSessionCount,
        2,
        reason: 'resuming the drawer threw away the restored invoices',
      );
      expect(after.cart, isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(
        storage.peek('user-1'),
        isNotNull,
        reason: 'and cleared them off the disk as well',
      );
    },
  );

  group('a restore that is still in flight', () {
    test(
      'an item rung up while the snapshot is still loading is not thrown away',
      () async {
        final storage = _SlowScopedJsonStorage();
        final api = _FakePosApiService(
          catalogPages: const {
            1: [_coffeeVariant, _teaVariant],
          },
        );

        // The shift before the power cut: one held invoice with coffee on it.
        final before = _viewModel(api, sessionStorage: storage);
        addTearDown(before.dispose);
        await before.restorePersistedSessions('user-1');
        before.addVariant(_coffeeVariant);
        await Future<void>.delayed(const Duration(milliseconds: 700));

        // Power back. The disk is slow, and the cashier does not wait for it.
        storage.loadDelay = const Duration(milliseconds: 300);
        final after = _viewModel(api, sessionStorage: storage);
        addTearDown(after.dispose);
        final restoring = after.restorePersistedSessions('user-1');
        after.addVariant(_teaVariant);
        await restoring;
        await _settle();

        final ids = <int>{};
        for (final session in after.saleSessions) {
          after.switchSaleSession(session.id);
          ids.addAll(after.cart.map((line) => line.variant.id));
        }
        expect(ids, contains(_coffeeVariant.id));
        expect(
          ids,
          contains(_teaVariant.id),
          reason: 'the item rung up during the restore was discarded',
        );
      },
    );

    test('a snapshot that cannot be read is never written over', () async {
      final storage = _SlowScopedJsonStorage();
      final api = _FakePosApiService(
        catalogPages: const {
          1: [_coffeeVariant, _teaVariant],
        },
      );

      final before = _viewModel(api, sessionStorage: storage);
      addTearDown(before.dispose);
      await before.restorePersistedSessions('user-1');
      before.addVariant(_coffeeVariant);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final saved = storage.peek('user-1');
      expect(saved, isNotNull);

      // The read fails. Whatever happens next, the held invoice on disk is the
      // only copy left — it must still be there for the next attempt.
      storage.failLoads = true;
      final after = _viewModel(api, sessionStorage: storage);
      addTearDown(after.dispose);
      await after.restorePersistedSessions('user-1');
      after.addVariant(_teaVariant);
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(
        storage.peek('user-1'),
        saved,
        reason: 'an unreadable snapshot was overwritten by the empty cart',
      );

      // ...and the next attempt, once the disk answers again, gets it back.
      storage.failLoads = false;
      final retry = _viewModel(api, sessionStorage: storage);
      addTearDown(retry.dispose);
      await retry.restorePersistedSessions('user-1');
      await _settle();
      expect(retry.cart.single.variant.id, _coffeeVariant.id);
    });

    test('signing in as someone else never clears their saved work', () async {
      final storage = _SlowScopedJsonStorage();
      final api = _FakePosApiService(
        catalogPages: const {
          1: [_coffeeVariant, _teaVariant],
        },
      );

      // Each cashier leaves a held invoice behind on this till.
      final theirs = _viewModel(api, sessionStorage: storage);
      addTearDown(theirs.dispose);
      await theirs.restorePersistedSessions('user-2');
      theirs.addVariant(_teaVariant);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final theirSnapshot = storage.peek('user-2');
      expect(theirSnapshot, isNotNull);

      // The next shift signs in on the same view model, and the disk is slow
      // enough that the debounce would fire before the snapshot is read.
      final till = _viewModel(api, sessionStorage: storage);
      addTearDown(till.dispose);
      await till.restorePersistedSessions('user-1');
      till.addVariant(_coffeeVariant);
      await Future<void>.delayed(const Duration(milliseconds: 700));

      storage.loadDelay = const Duration(milliseconds: 900);
      await till.restorePersistedSessions('user-2');
      await _settle();

      expect(
        storage.clearedScopes,
        isNot(contains('user-2')),
        reason: "the incoming cashier's saved work was cleared before it "
            'had been read',
      );
      expect(till.cart.single.variant.id, _teaVariant.id);
      expect(storage.peek('user-1'), isNotNull);
    });
  });
}

PosViewModel _viewModel(
  _FakePosApiService apiService, {
  AnalyticsEngine? analyticsEngine,
  ScopedJsonStorage? sessionStorage,
  ScanFeedbackPlayer? scanFeedback,
  PrintingRepository? printingRepository,
  Duration checkoutPrintDeadline = const Duration(seconds: 20),
}) {
  return PosViewModel(
    CatalogRepository(apiService),
    RegisterSessionRepository(apiService),
    SaleRepository(apiService),
    ShopSettingsRepository(apiService),
    printingRepository ??
        PrintingRepository(
          apiService,
          serialTransport: const _NoopPrintTransport(),
          bluetoothTransport: const _NoopPrintTransport(),
          wifiTransport: const _NoopPrintTransport(),
          fakeTransport: const _NoopPrintTransport(),
        ),
    analyticsEngine: analyticsEngine,
    sessionStorage: sessionStorage ?? MemoryScopedJsonStorage(),
    scanFeedback: scanFeedback,
    checkoutPrintDeadline: checkoutPrintDeadline,
  );
}

/// Fails every catalog lookup, driving the barcode path into its error status.
class _BarcodeErrorPosApiService extends _FakePosApiService {
  _BarcodeErrorPosApiService();

  @override
  Future<ProductVariantPage> fetchProductVariants({
    required ModelQuery query,
    int page = 1,
  }) async {
    throw Exception('catalog lookup unavailable');
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

SaleOrder _saleOrder({
  required double total,
  required List<SaleOrderLine> lines,
  List<PrintJob> kitchenPrintJobs = const [],
}) {
  return SaleOrder(
    id: 100,
    receiptNumber: 'R-100',
    status: 'paid',
    lines: lines,
    kitchenPrintJobs: kitchenPrintJobs,
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

/// A produce line: the catalog stores the scale's short item code, and the
/// product is measured rather than counted.
const _tomatoVariant = ProductVariant(
  id: 108,
  productId: 8,
  productName: 'طماطم',
  displayName: 'طماطم',
  fullName: 'طماطم',
  sku: 'TOM-001',
  unitPrice: 40,
  quantityOnHand: 100,
  barcode: '12345',
  unit: 'kg',
  isDefault: true,
);

/// The same short code on a product sold by the piece.
const _breadVariant = ProductVariant(
  id: 109,
  productId: 9,
  productName: 'خبز',
  displayName: 'خبز',
  fullName: 'خبز',
  sku: 'BRD-001',
  unitPrice: 1.5,
  quantityOnHand: 50,
  barcode: '54321',
  isDefault: true,
);

const _teaVariant = ProductVariant(
  id: 102,
  productId: 2,
  productName: 'شاي بالنعناع',
  displayName: 'شاي بالنعناع',
  fullName: 'شاي بالنعناع',
  sku: 'TEA-001',
  unitPrice: 2.75,
  quantityOnHand: 8,
  barcode: '1000002',
  isDefault: true,
);

// Eggs: a fractional tray unit with its own packaging barcode ('4000002') —
// exercises decimal quick-typing after a unit-barcode scan.
const _eggVariant = ProductVariant(
  id: 105,
  productId: 7,
  productName: 'بيض مائدة',
  displayName: 'بيض مائدة',
  fullName: 'بيض مائدة',
  sku: 'EGG-001',
  unitPrice: 0.75,
  quantityOnHand: 300,
  barcode: '4000001',
  isDefault: true,
  productDetail: Product(
    id: 7,
    name: 'بيض مائدة',
    quantityOnHand: 300,
    units: [
      ProductUnit(
        unit: UnitOfMeasure(
          id: 11,
          code: 'tray',
          name: 'طبق',
          allowsFractional: true,
        ),
        factorToBase: 30,
        price: 15,
        barcodes: ['4000002'],
      ),
    ],
  ),
);

// A product whose carton carries its own packaging barcode ('3000002'): the
// unit-barcode scan flow resolves it through productDetail.units.
const _juiceVariant = ProductVariant(
  id: 104,
  productId: 6,
  productName: 'عصير صافي',
  displayName: 'عصير صافي',
  fullName: 'عصير صافي',
  sku: 'JUICE-001',
  unitPrice: 1.0,
  quantityOnHand: 48,
  barcode: '3000001',
  isDefault: true,
  productDetail: Product(
    id: 6,
    name: 'عصير صافي',
    quantityOnHand: 48,
    units: [
      ProductUnit(
        unit: UnitOfMeasure(id: 9, code: 'carton', name: 'كرتون'),
        factorToBase: 24,
        barcodes: ['3000002'],
      ),
    ],
  ),
);

const _coffeeBeansVariant = ProductVariant(
  id: 103,
  productId: 3,
  productName: 'حبوب قهوة',
  displayName: 'حبوب قهوة',
  fullName: 'حبوب قهوة',
  sku: 'COF-002',
  unitPrice: 9,
  quantityOnHand: 5,
  barcode: '1000003',
  isDefault: true,
);

const _shirtRedLargeVariant = ProductVariant(
  id: 201,
  productId: 4,
  productName: 'قميص',
  name: 'أحمر / L',
  displayName: 'أحمر / L',
  fullName: 'قميص - أحمر / L',
  sku: 'SHIRT-RED-L',
  unitPrice: 12,
  quantityOnHand: 3,
  barcode: '2000001',
  isDefault: true,
);

const _shirtBlueMediumVariant = ProductVariant(
  id: 202,
  productId: 4,
  productName: 'قميص',
  name: 'أزرق / M',
  displayName: 'أزرق / M',
  fullName: 'قميص - أزرق / M',
  sku: 'SHIRT-BLUE-M',
  unitPrice: 11,
  quantityOnHand: 4,
  barcode: '2000002',
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
  enableOnlineInvoices: false,
  requireOpeningCash: true,
  autoPrintReceipts: false,
  allowOverselling: false,
  preventSellingAtLoss: true,
  lowStockThreshold: 5,
  cashierReturnWindowHours: 42,
  enableCashPayments: true,
  enableCardPayments: true,
  enableTransferPayments: true,
  requireCardPaymentReceipt: false,
  trustedCardTerminalIds: [],
  cardCommissionPercent: 1,
  transferCommissionPercent: 0,
);

/// [_settings] with automatic receipt printing on, so checkout exercises the
/// post-sale print path (and its failure guards).
/// Auto-print with a floor under it: three lines, or twenty dinars. A sale that
/// clears either prints; anything smaller does not.
const _autoPrintFloorSettings = ShopSettings(
  shopName: 'نقطة البيع',
  receiptHeader: '',
  receiptFooter: '',
  enableOnlineInvoices: false,
  requireOpeningCash: true,
  autoPrintReceipts: true,
  autoPrintMinLineCount: 3,
  autoPrintMinTotal: 20,
  allowOverselling: false,
  preventSellingAtLoss: true,
  lowStockThreshold: 5,
  cashierReturnWindowHours: 42,
  enableCashPayments: true,
  enableCardPayments: true,
  enableTransferPayments: true,
  requireCardPaymentReceipt: false,
  trustedCardTerminalIds: [],
  cardCommissionPercent: 1,
  transferCommissionPercent: 0,
);

const _autoPrintSettings = ShopSettings(
  shopName: 'نقطة البيع',
  receiptHeader: '',
  receiptFooter: '',
  enableOnlineInvoices: false,
  requireOpeningCash: true,
  autoPrintReceipts: true,
  allowOverselling: false,
  preventSellingAtLoss: true,
  lowStockThreshold: 5,
  cashierReturnWindowHours: 42,
  enableCashPayments: true,
  enableCardPayments: true,
  enableTransferPayments: true,
  requireCardPaymentReceipt: false,
  trustedCardTerminalIds: [],
  cardCommissionPercent: 1,
  transferCommissionPercent: 0,
);

/// A printing repository whose default printer is a thermal receipt printer and
/// whose invoice print resolves to a test-controlled [invoiceResult] — hang it
/// (a never-completing Future) or fail it (an errored Future) to model a broken
/// printer without any real device or transport.
class _StubPrintingRepository extends PrintingRepository {
  _StubPrintingRepository(super.service, {required this.invoiceResult})
    : super(
        serialTransport: const _NoopPrintTransport(),
        bluetoothTransport: const _NoopPrintTransport(),
        wifiTransport: const _NoopPrintTransport(),
        fakeTransport: const _NoopPrintTransport(),
      );

  /// Built fresh per print so an errored future is first listened to by the
  /// guard under test (not left dangling as an unhandled zone error at setup).
  final Future<PrintTransportResult> Function() invoiceResult;
  int invoiceCalls = 0;
  int kitchenConfigLoads = 0;

  @override
  Future<Map<int, PrinterConfig>> loadKitchenStationConfigs() async {
    kitchenConfigLoads += 1;
    return const {};
  }

  @override
  Future<Result<PrinterConfig>> loadDefaultPrinterConfig() async {
    return const Ok(
      PrinterConfig(
        endpoint: PrinterEndpoint(
          kind: PrintTransportKind.wifi,
          name: 'stub-thermal',
          address: '10.0.0.9',
        ),
      ),
    );
  }

  @override
  Future<PrintTransportResult> printSaleInvoice({
    required SaleOrder order,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
  }) {
    invoiceCalls += 1;
    return invoiceResult();
  }
}

class _CatalogRequest {
  const _CatalogRequest({required this.query, required this.page});

  final ProductQuery query;
  final int page;
}

class _FakePosApiService extends PosApiService {
  _FakePosApiService({
    this.checkoutCompleter,
    this.onCheckout,
    this.onFetchProducts,
    this.onPreviewDiscounts,
    this.discountsVersion,
    this.catalogPages = const {},
    this.shopSettings,
    this.scaleRules = const [],
    this.unitsOfMeasure,
  }) : super(
         client: MockClient((_) async => http.Response('{}', 500)),
         baseUrl: 'http://pointy.test/api',
       );

  /// Overrides the settings returned by [fetchShopSettings] (defaults to
  /// [_settings]); lets a test flip flags like `autoPrintReceipts`.
  final ShopSettings? shopSettings;

  /// The scale label layouts this shop has configured. Empty by default, so
  /// every other test in this file scans plain barcodes exactly as before.
  final List<ScaleBarcodeRule> scaleRules;

  /// The shop's unit registry. Null means "unreachable", which is the state
  /// every other test in this file runs in — the till then falls back to the
  /// built-in unit codes.
  final List<UnitOfMeasure>? unitsOfMeasure;

  @override
  Future<List<ScaleBarcodeRule>> fetchScaleBarcodeRules({
    bool activeOnly = true,
  }) async => scaleRules;

  @override
  Future<UnitOfMeasurePage> fetchUnitsOfMeasure({
    int page = 1,
    bool? active,
  }) async {
    final units = unitsOfMeasure;
    if (units == null) {
      throw Exception('no unit registry');
    }
    return UnitOfMeasurePage(units: units, hasMore: false);
  }

  /// Overrides the discounts version the real session learns from response
  /// headers, so the no-rules latch can be exercised without HTTP plumbing.
  final String? discountsVersion;
  final Future<SaleDiscountPreview> Function(SaleDiscountPreviewDraft draft)?
  onPreviewDiscounts;
  int previewRequests = 0;

  @override
  String? get discountsVersionToken => discountsVersion;

  @override
  Future<SaleDiscountPreview> previewSaleDiscounts(
    SaleDiscountPreviewDraft draft,
  ) {
    previewRequests += 1;
    final handler = onPreviewDiscounts;
    if (handler != null) {
      return handler(draft);
    }
    return super.previewSaleDiscounts(draft);
  }

  final Completer<SaleOrder>? checkoutCompleter;
  final Future<SaleOrder> Function(
    SaleCheckoutDraft draft,
    String? idempotencyKey,
  )?
  onCheckout;
  final ProductPage Function(ProductQuery query, int page)? onFetchProducts;
  final Map<int, List<ProductVariant>> catalogPages;
  final List<_CatalogRequest> catalogRequests = [];
  SaleCheckoutDraft? capturedCheckoutDraft;
  String? capturedCheckoutIdempotencyKey;

  @override
  Future<RegisterSession?> fetchCurrentRegisterSession() async {
    return _openSession;
  }

  @override
  Future<ShopSettings> fetchShopSettings() async {
    return shopSettings ?? _settings;
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
      products: (catalogPages[page] ?? const [])
          .map(Product.fromVariant)
          .toList(growable: false),
      hasMore: catalogPages.containsKey(page + 1),
    );
  }

  @override
  Future<ProductVariantPage> fetchProductVariants({
    required ModelQuery query,
    int page = 1,
  }) async {
    return ProductVariantPage(
      variants: catalogPages[page] ?? const [],
      hasMore: catalogPages.containsKey(page + 1),
    );
  }

  @override
  Future<ProductVariantPage> fetchVariantsForProduct(
    int productId, {
    int page = 1,
  }) async {
    final variants = catalogPages.values
        .expand((variants) => variants)
        .where((variant) => variant.productId == productId)
        .toList(growable: false);
    return ProductVariantPage(variants: variants, hasMore: false);
  }

  @override
  Future<SaleOrder> checkout(
    SaleCheckoutDraft draft, {
    String? idempotencyKey,
  }) {
    capturedCheckoutDraft = draft;
    capturedCheckoutIdempotencyKey = idempotencyKey;
    final customCheckout = onCheckout;
    if (customCheckout != null) {
      return customCheckout(draft, idempotencyKey);
    }
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

class _FakeAnalyticsSink implements AnalyticsEventSink {
  final List<AnalyticsEventDraft> acceptedEvents = [];

  @override
  Future<Result<AnalyticsIngestResult>> ingestEvents(
    List<AnalyticsEventDraft> events,
  ) async {
    acceptedEvents.addAll(events);
    return Ok(
      AnalyticsIngestResult(
        accepted: events.length,
        duplicates: 0,
        eventIds: events.map((event) => event.clientEventId).toList(),
      ),
    );
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


/// Auto-print with a floor: a shop that sells one loaf of bread at a time does
/// not want a slip for every loaf, but the cashier must still be able to print
/// one when the customer asks.
///
/// The floor is configured from a modern client — this branch ships no settings
/// UI for it (see ShopSettingsDraft) — so what is under test here is only that
/// a Win8 till *honours* a floor the shop already set.
void _registerAutoPrintFloorTests() {
  group('the auto-print floor', () {
    Future<(PosViewModel, _StubPrintingRepository, List<SaleCheckoutDraft>)>
    readyViewModel() async {
      final drafts = <SaleCheckoutDraft>[];
      final apiService = _FakePosApiService(
        shopSettings: _autoPrintFloorSettings,
        catalogPages: const {
          1: [_coffeeVariant, _teaVariant, _coffeeBeansVariant],
        },
        onCheckout: (draft, _) async {
          drafts.add(draft);
          // An آجل sale carries no payment, so the total comes off the draft.
          return _saleOrder(
            total: draft.payments.fold<double>(0, (sum, p) => sum + p.amount),
            lines: const [],
          );
        },
      );
      final printing = _StubPrintingRepository(
        apiService,
        invoiceResult: () async =>
            const PrintTransportResult.success('printed'),
      );
      final viewModel = _viewModel(apiService, printingRepository: printing);
      addTearDown(viewModel.dispose);

      await viewModel.loadCurrentRegisterSession();
      await viewModel.resumeRegisterSession();
      await viewModel.loadCheckoutSettings();
      return (viewModel, printing, drafts);
    }

    test('a single cheap line does not print itself', () async {
      final (viewModel, printing, drafts) = await readyViewModel();

      viewModel.addVariant(_coffeeVariant);
      await _settle();

      expect(viewModel.cartWouldAutoPrintReceipt(), isFalse);
      await viewModel.checkoutCurrentSale(
        payments: const [
          SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 3.5),
        ],
      );
      await _settle();

      expect(printing.invoiceCalls, 0);
      // And the backend is told not to queue one either, so the two routes
      // cannot disagree about the same sale.
      expect(drafts.single.toJson()['receipt_delivery'], isNull);
    });

    test('a basket of cheap things prints on line count', () async {
      final (viewModel, printing, _) = await readyViewModel();

      viewModel.addVariant(_coffeeVariant);
      viewModel.addVariant(_teaVariant);
      viewModel.addVariant(_coffeeBeansVariant);
      await _settle();

      expect(viewModel.cart, hasLength(3));
      expect(viewModel.cartWouldAutoPrintReceipt(), isTrue);
      await viewModel.checkoutCurrentSale(
        payments: const [
          SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 15.25),
        ],
      );
      await _settle();

      expect(printing.invoiceCalls, 1);
    });

    test('one expensive line prints on the total', () async {
      final (viewModel, printing, _) = await readyViewModel();

      viewModel.addVariant(_coffeeBeansVariant);
      viewModel.setVariantQuantity(_coffeeBeansVariant, 3);
      await _settle();

      expect(viewModel.cart, hasLength(1));
      expect(viewModel.total, 27);
      expect(viewModel.cartWouldAutoPrintReceipt(), isTrue);
      await viewModel.checkoutCurrentSale(
        payments: const [
          SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 27),
        ],
      );
      await _settle();

      expect(printing.invoiceCalls, 1);
    });

    test('the cashier can still print a sale under the floor', () async {
      final (viewModel, printing, _) = await readyViewModel();

      viewModel.addVariant(_coffeeVariant);
      await _settle();

      // The box is back precisely because this sale would not print itself.
      expect(viewModel.shouldShowPrintInvoiceCheckbox, isTrue);
      viewModel.updatePrintInvoiceAfterPayment(true);

      await viewModel.checkoutCurrentSale(
        payments: const [
          SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 3.5),
        ],
      );
      await _settle();

      expect(printing.invoiceCalls, 1);
    });

    test('the box disappears again once the cart clears the floor', () async {
      final (viewModel, _, _) = await readyViewModel();

      viewModel.addVariant(_coffeeVariant);
      await _settle();
      expect(viewModel.shouldShowPrintInvoiceCheckbox, isTrue);

      viewModel.addVariant(_teaVariant);
      viewModel.addVariant(_coffeeBeansVariant);
      await _settle();

      expect(viewModel.shouldShowPrintInvoiceCheckbox, isFalse);
    });

    test('an آجل invoice under the floor still prints', () async {
      // The floor holds back receipts for transient carts. A debt invoice is
      // the customer's only record of what they owe, so it is not one.
      final (viewModel, printing, _) = await readyViewModel();

      viewModel.addVariant(_coffeeVariant);
      await _settle();

      expect(
        viewModel.cartWouldAutoPrintReceipt(saleType: SaleType.credit),
        isTrue,
      );
      await viewModel.checkoutCurrentSale(
        payments: const [],
        saleType: SaleType.credit,
      );
      await _settle();

      expect(printing.invoiceCalls, 1);
    });
  });
}

/// The two things a cashier does most that left no trace at all.
///
/// A scan that matches nothing makes no request worth logging, and a search
/// that finds nothing is an ordinary 200 with an empty page — so from an export
/// both are indistinguishable from never having happened. The field export
/// therefore showed a shop with a tidy catalog and no way to tell how often the
/// till failed the person standing at it.
void _registerTillBlindSpotTests() {
  AnalyticsEngine engineWith(_FakeAnalyticsSink sink, String installationId) {
    return AnalyticsEngine(
      sink,
      storage: MemoryAnalyticsQueueStorage(installationId: installationId),
      flushInterval: const Duration(hours: 1),
    )..setCurrentUser(1);
  }

  group('a scan that finds nothing is recorded', () {
    test('the code that missed is written down, with how it was entered',
        () async {
      final sink = _FakeAnalyticsSink();
      final engine = engineWith(sink, 'scan-miss');
      final viewModel = _viewModel(
        _FakePosApiService(
          catalogPages: const {
            1: [_coffeeVariant],
          },
        ),
        analyticsEngine: engine,
      );
      addTearDown(viewModel.dispose);
      addTearDown(engine.dispose);

      expect(await viewModel.addVariantByBarcode('1000001'), isTrue);
      expect(
        await viewModel.addVariantByBarcode(
          '5000009',
          source: 'hardware_scanner',
        ),
        isFalse,
      );
      await _settle();
      await engine.flush();

      final misses = sink.acceptedEvents
          .where((event) => event.name == 'pos.scan.unmatched')
          .toList(growable: false);

      expect(misses, hasLength(1), reason: 'the hit must not be recorded too');
      // The list of codes here is directly actionable: these are the products
      // whose barcode needs adding, in the order the shop meets them.
      expect(misses.single.attributes['barcode'], '5000009');
      expect(misses.single.attributes['source'], 'hardware_scanner');
      expect(misses.single.attributes['is_numeric'], isTrue);
      expect(misses.single.metrics['barcode_length'], 7);
      expect(misses.single.severity, AnalyticsEventSeverity.warning);
    });

    test('every attempt counts, because trying five times is the finding',
        () async {
      final sink = _FakeAnalyticsSink();
      final engine = engineWith(sink, 'scan-retry');
      final viewModel = _viewModel(
        _FakePosApiService(catalogPages: const {1: []}),
        analyticsEngine: engine,
      );
      addTearDown(viewModel.dispose);
      addTearDown(engine.dispose);

      await viewModel.addVariantByBarcode('5000009');
      await viewModel.addVariantByBarcode('5000009');
      await viewModel.addVariantByBarcode('5000009');
      await _settle();
      await engine.flush();

      expect(
        sink.acceptedEvents
            .where((event) => event.name == 'pos.scan.unmatched')
            .length,
        3,
        reason: 'a cashier scanning the same missing item three times is a '
            'stronger signal than one that did, not a duplicate to collapse',
      );
    });
  });

  group('what the cashier searched for is recorded', () {
    test('a search that finds nothing says what it was looking for', () async {
      final sink = _FakeAnalyticsSink();
      final engine = engineWith(sink, 'search-miss');
      final apiService = _FakePosApiService(
        onFetchProducts: (query, page) =>
            const ProductPage(products: [], hasMore: false),
      );
      final viewModel = _viewModel(apiService, analyticsEngine: engine);
      addTearDown(viewModel.dispose);
      addTearDown(engine.dispose);

      await viewModel.updateSearch('قهوة');
      await _settle();
      await engine.flush();

      final searches = sink.acceptedEvents
          .where((event) => event.name == 'catalog.search')
          .toList(growable: false);

      expect(searches, hasLength(1));
      expect(searches.single.attributes['term'], 'قهوة');
      expect(searches.single.attributes['has_results'], isFalse);
      expect(searches.single.metrics['result_count'], 0);
      expect(searches.single.metrics['term_length'], 4);
      expect(searches.single.metrics['duration_ms'], isNotNull);
      expect(searches.single.severity, AnalyticsEventSeverity.warning);
    });

    test('a search that lands is recorded too, so the miss rate has a floor',
        () async {
      final sink = _FakeAnalyticsSink();
      final engine = engineWith(sink, 'search-hit');
      final viewModel = _viewModel(
        _FakePosApiService(
          catalogPages: const {
            1: [_coffeeVariant],
          },
        ),
        analyticsEngine: engine,
      );
      addTearDown(viewModel.dispose);
      addTearDown(engine.dispose);

      await viewModel.updateSearch('coffee');
      await _settle();
      await engine.flush();

      final search = sink.acceptedEvents.firstWhere(
        (event) => event.name == 'catalog.search',
      );

      expect(search.attributes['has_results'], isTrue);
      expect(search.metrics['result_count'], greaterThan(0));
      expect(search.severity, AnalyticsEventSeverity.info);
    });

    test('browsing is not a search', () async {
      // The grid reloads for a screen re-entry and a filter sync too. Counting
      // those would turn one cashier hunt into several, and the resulting miss
      // rate would be measured against an invented total.
      final sink = _FakeAnalyticsSink();
      final engine = engineWith(sink, 'search-browse');
      final viewModel = _viewModel(
        _FakePosApiService(),
        analyticsEngine: engine,
      );
      addTearDown(viewModel.dispose);
      addTearDown(engine.dispose);

      await viewModel.loadCatalog();
      await viewModel.loadMoreCatalog();
      await _settle();
      await engine.flush();

      expect(
        sink.acceptedEvents.where((event) => event.name == 'catalog.search'),
        isEmpty,
      );
    });

    test('re-running the same search does not re-record it', () async {
      final sink = _FakeAnalyticsSink();
      final engine = engineWith(sink, 'search-repeat');
      final viewModel = _viewModel(
        _FakePosApiService(),
        analyticsEngine: engine,
      );
      addTearDown(viewModel.dispose);
      addTearDown(engine.dispose);

      await viewModel.updateSearch('coffee');
      await viewModel.updateSearch('coffee');
      await _settle();
      await engine.flush();

      expect(
        sink.acceptedEvents
            .where((event) => event.name == 'catalog.search')
            .length,
        1,
      );
    });
  });
}

/// A [ScopedJsonStorage] whose reads can be made slow or made to fail, so the
/// window between "the cashier is back at the till" and "the snapshot has been
/// read off the disk" can actually be exercised.
class _SlowScopedJsonStorage implements ScopedJsonStorage {
  final Map<String, String> _store = {};

  Duration loadDelay = Duration.zero;
  bool failLoads = false;
  final List<String> clearedScopes = [];

  String? peek(String scope) => _store[scope];

  @override
  Future<String?> load(String scope) async {
    if (loadDelay > Duration.zero) {
      await Future<void>.delayed(loadDelay);
    }
    if (failLoads) {
      throw Exception('the disk did not answer');
    }
    return _store[scope];
  }

  @override
  Future<void> save(String scope, String json) async => _store[scope] = json;

  @override
  Future<void> clear(String scope) async {
    clearedScopes.add(scope);
    _store.remove(scope);
  }
}
