import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/core/analytics_engine.dart';
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
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/shared/unit_options.dart';

void main() {
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

  test('re-adding an existing cart line makes it the newest line', () async {
    final viewModel = _viewModel(_FakePosApiService());
    addTearDown(viewModel.dispose);

    viewModel.addVariant(_coffeeVariant);
    viewModel.addVariant(_teaVariant);
    viewModel.addVariant(_coffeeVariant);

    expect(viewModel.cart.map((line) => line.variant.id), [
      _teaVariant.id,
      _coffeeVariant.id,
    ]);
    expect(viewModel.cart.last.quantity, 2);
    expect(viewModel.cart.reversed.first.variant.id, _coffeeVariant.id);
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

  group('scan quick adjust', () {
    test('digits after a scan replace the line quantity and accumulate '
        'across keystrokes', () async {
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
      expect(viewModel.lastScannedCartLine, isNotNull);

      expect(viewModel.applyQuickQuantityDigits('5'), isTrue);
      expect(viewModel.cart.single.quantity, 5);
      // A second digit within the idle window appends: 5 → 50.
      expect(viewModel.applyQuickQuantityDigits('0'), isTrue);
      expect(viewModel.cart.single.quantity, 50);
    });

    test('a fresh scan re-arms the digit buffer', () async {
      final viewModel = _viewModel(
        _FakePosApiService(
          catalogPages: const {
            1: [_coffeeVariant],
          },
        ),
      );
      addTearDown(viewModel.dispose);

      await viewModel.addVariantByBarcode('1000001');
      viewModel.applyQuickQuantityDigits('5');
      expect(viewModel.cart.single.quantity, 5);

      // Re-scanning the same product increments its line (5 → 6) and starts a
      // fresh buffer, so the next digit replaces rather than appending.
      await viewModel.addVariantByBarcode('1000001');
      expect(viewModel.cart.single.quantity, 6);
      expect(viewModel.applyQuickQuantityDigits('3'), isTrue);
      expect(viewModel.cart.single.quantity, 3);
    });

    test('digits do nothing after a plain cart-button add', () {
      final viewModel = _viewModel(_FakePosApiService());
      addTearDown(viewModel.dispose);

      viewModel.addVariant(_coffeeVariant);
      expect(viewModel.lastScannedCartLine, isNull);
      expect(viewModel.applyQuickQuantityDigits('7'), isFalse);
      expect(viewModel.cart.single.quantity, 1);
    });

    test('a catalog tile add arms the quick adjust like a scan does', () {
      final viewModel = _viewModel(_FakePosApiService());
      addTearDown(viewModel.dispose);

      viewModel.addVariant(_coffeeVariant, source: 'product_tile');
      expect(viewModel.lastScannedCartLine, isNotNull);
      expect(viewModel.applyQuickQuantityDigits('1'), isTrue);
      expect(viewModel.applyQuickQuantityDigits('2'), isTrue);
      expect(viewModel.cart.single.quantity, 12);
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
      // The scan armed the quick adjust on the carton line.
      expect(viewModel.applyQuickQuantityDigits('3'), isTrue);
      expect(viewModel.cart.single.quantity, 3);
    });

    test('applyQuickUnit switches the scanned line unit of measure', () async {
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
      expect(viewModel.applyQuickUnit(box), isTrue);
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
      expect(viewModel.applyQuickUnit(base), isTrue);
      expect(viewModel.cart.single.unitCode, '');
      expect(viewModel.cart.single.unitPriceOverride, isNull);
    });
  });
}

PosViewModel _viewModel(
  _FakePosApiService apiService, {
  AnalyticsEngine? analyticsEngine,
  ScopedJsonStorage? sessionStorage,
}) {
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
    analyticsEngine: analyticsEngine,
    sessionStorage: sessionStorage ?? MemoryScopedJsonStorage(),
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
    this.catalogPages = const {},
  }) : super(
         client: MockClient((_) async => http.Response('{}', 500)),
         baseUrl: 'http://pointy.test/api',
       );

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
