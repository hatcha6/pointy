import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/service_kinds.dart';
import 'package:pointy_frontend/src/data/models/service_quote.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';

/// An airtime top-up or a bill payment in the cart: an ordinary service line
/// carrying the server's own quote, which never merges, survives a held
/// invoice, and travels to checkout in the shape the server reads.
void main() {
  const airtime = ServiceQuote(
    kind: ServiceKind.airtime,
    optionCode: 'air:289:5000:XOF',
    optionLabel: 'أورنج مالي · 5,000 فرنك أفريقي',
    subscriberRef: '+22370123456',
    price: 96.5,
    receiveAmount: '5000',
    receiveCurrency: 'XOF',
    quote: 'sealed.air:289:5000:XOF.96.50',
    serviceVariantId: 9301,
  );
  const bill = ServiceQuote(
    kind: ServiceKind.bill,
    optionCode: 'bill:5:5000:NGN',
    optionLabel: 'كهرباء إيكيجا (مسبقة الدفع) · 5,000 نيرة نيجيرية',
    subscriberRef: '04223568280',
    price: 36,
    receiveAmount: '5000',
    receiveCurrency: 'NGN',
    quote: 'sealed.bill:5:5000:NGN.36.00',
    serviceVariantId: 9302,
  );

  late _CapturingSales sales;
  late MemoryScopedJsonStorage storage;

  PosViewModel build() {
    sales = _CapturingSales();
    storage = MemoryScopedJsonStorage();
    return PosViewModel(
      _EmptyCatalog(),
      _OpenRegister(),
      sales,
      ShopSettingsRepository(PosApiService()),
      PrintingRepository(PosApiService()),
      sessionStorage: storage,
    );
  }

  Future<PosViewModel> open() async {
    final viewModel = build();
    addTearDown(viewModel.dispose);
    await viewModel.loadCurrentRegisterSession();
    await viewModel.resumeRegisterSession();
    return viewModel;
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  group('adding', () {
    test('puts one service line in the cart, priced by the server', () async {
      final viewModel = await open();

      final added = viewModel.addServiceLine(
        quote: airtime,
        variantId: 9301,
        title: 'شحن مباشر',
      );

      expect(added, isTrue, reason: 'the screen is told it went in');
      final line = viewModel.cart.single;
      expect(line.variant.id, 9301);
      expect(line.variant.isService, isTrue);
      expect(line.variant.productLabel, 'شحن مباشر');
      expect(line.quantity, 1);
      expect(line.unitPrice, 96.5);
      expect(line.subtotal, 96.5);
      expect(line.integration!.provider, 'pointy');
      expect(line.integration!.subscriberRef, '+22370123456');
      expect(line.integration!.optionCode, 'air:289:5000:XOF');
      expect(line.integration!.optionLabel, 'أورنج مالي · 5,000 فرنك أفريقي');
      expect(line.integration!.quote, 'sealed.air:289:5000:XOF.96.50');
      expect(line.isDirectService, isTrue);
      expect(line.integration!.isAirtime, isTrue);
      expect(line.integration!.isBill, isFalse);
      expect(line.isProviderLine, isTrue);
      expect(
        line.allowsQuantityEdit,
        isFalse,
        reason: 'one purchase, one line',
      );
    });

    test(
      'a bill is a line too, told apart from airtime by its option code',
      () async {
        final viewModel = await open();

        viewModel.addServiceLine(
          quote: bill,
          variantId: 9302,
          title: 'دفع فاتورة',
        );

        final line = viewModel.cart.single;
        expect(line.integration!.isBill, isTrue);
        expect(line.integration!.isAirtime, isFalse);
        expect(line.isDirectService, isTrue);
        expect(line.variant.id, 9302);
      },
    );

    test('never merges: the same top-up twice is two purchases', () async {
      final viewModel = await open();

      for (var i = 0; i < 2; i++) {
        viewModel.addServiceLine(
          quote: airtime,
          variantId: 9301,
          title: 'شحن مباشر',
        );
      }

      expect(viewModel.cart, hasLength(2));
      expect(viewModel.cart.map((line) => line.lineKey).toSet(), hasLength(2));
      expect(viewModel.total, 193);
    });

    test('takes the quote\'s own product when the menu named none', () async {
      final viewModel = await open();
      viewModel.addServiceLine(quote: airtime, variantId: 0, title: 'شحن');

      expect(viewModel.cart.single.variant.id, 9301);
    });

    test('refuses a quote that cannot be sold', () async {
      final viewModel = await open();
      const unsealed = ServiceQuote(
        kind: ServiceKind.airtime,
        optionCode: 'air:1:2:XOF',
        optionLabel: '',
        subscriberRef: '+1',
        price: 1,
        receiveAmount: '2',
        receiveCurrency: 'XOF',
        quote: '',
        serviceVariantId: 9301,
      );

      final added = viewModel.addServiceLine(
        quote: unsealed,
        variantId: 9301,
        title: 'x',
      );

      expect(added, isFalse);
      expect(viewModel.cart, isEmpty);
    });

    test('refuses a quote with no price in it', () async {
      final viewModel = await open();
      const free = ServiceQuote(
        kind: ServiceKind.airtime,
        optionCode: 'air:1:2:XOF',
        optionLabel: '',
        subscriberRef: '+22370123456',
        price: 0,
        receiveAmount: '2',
        receiveCurrency: 'XOF',
        quote: 'sealed',
        serviceVariantId: 9301,
      );

      final added = viewModel.addServiceLine(
        quote: free,
        variantId: 9301,
        title: 'x',
      );

      expect(added, isFalse);
      expect(viewModel.cart, isEmpty);
    });

    test('is not possible while a sale is being checked out', () async {
      final viewModel = await open();
      viewModel.addServiceLine(quote: airtime, variantId: 9301, title: 'شحن');
      sales.holdCheckout = true;
      final checkout = viewModel.checkoutCurrentSale(
        payments: const [
          SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 96.5),
        ],
      );
      await settle();

      final added = viewModel.addServiceLine(
        quote: bill,
        variantId: 9302,
        title: 'فاتورة',
      );

      expect(
        added,
        isFalse,
        reason: 'the screen keeps what was built, and says',
      );
      expect(viewModel.cart, hasLength(1));
      sales.release();
      await checkout;
    });
  });

  group('the line', () {
    test(
      'survives a held invoice: persisted, restored, still a top-up',
      () async {
        final first = build();
        addTearDown(first.dispose);
        await first.loadCurrentRegisterSession();
        await first.resumeRegisterSession();
        await first.restorePersistedSessions('user-1');
        first.addServiceLine(
          quote: airtime,
          variantId: 9301,
          title: 'شحن مباشر',
        );
        first.addServiceLine(quote: bill, variantId: 9302, title: 'دفع فاتورة');
        await Future<void>.delayed(const Duration(milliseconds: 700));

        final second = PosViewModel(
          _EmptyCatalog(),
          _OpenRegister(),
          _CapturingSales(),
          ShopSettingsRepository(PosApiService()),
          PrintingRepository(PosApiService()),
          sessionStorage: storage,
        );
        addTearDown(second.dispose);
        await second.restorePersistedSessions('user-1');

        expect(second.cart, hasLength(2));
        final restored = second.cart.first;
        expect(restored.integration!.optionCode, 'air:289:5000:XOF');
        expect(restored.integration!.quote, 'sealed.air:289:5000:XOF.96.50');
        expect(restored.integration!.subscriberRef, '+22370123456');
        expect(restored.isDirectService, isTrue);
        expect(restored.unitPrice, 96.5);
        expect(second.cart.last.integration!.isBill, isTrue);
      },
    );

    test(
      'remembers when its quote was given, for the age of a held line',
      () async {
        final viewModel = await open();
        final before = DateTime.now().subtract(const Duration(seconds: 1));
        viewModel.addServiceLine(quote: airtime, variantId: 9301, title: 'شحن');

        final line = viewModel.cart.single;
        expect(line.integration!.quotedAt, isNotNull);
        expect(line.integration!.quotedAt!.isAfter(before), isTrue);
        final restored = CartLine.fromJson(
          (jsonDecode(jsonEncode(line.toJson())) as Map)
              .cast<String, Object?>(),
        );
        expect(
          restored.integration!.quotedAt!.millisecondsSinceEpoch,
          line.integration!.quotedAt!.millisecondsSinceEpoch,
        );
      },
    );

    test('keeps that time to itself: the server is never sent it', () async {
      final viewModel = await open();
      viewModel.addServiceLine(quote: airtime, variantId: 9301, title: 'شحن');

      await viewModel.checkoutCurrentSale(
        payments: const [
          SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 96.5),
        ],
      );

      final lines = (sales.captured!.toJson()['lines']! as List)
          .cast<Map<String, Object?>>();
      expect(
        (lines.single['integration']! as Map).containsKey('quoted_at'),
        isFalse,
      );
    });

    test('knows it was sold in test mode, until the sale is made', () async {
      final viewModel = await open();
      viewModel.addServiceLine(
        quote: airtime,
        variantId: 9301,
        title: 'شحن',
        testMode: true,
      );
      viewModel.addServiceLine(quote: bill, variantId: 9302, title: 'فاتورة');

      expect(viewModel.cart.first.integration!.testMode, isTrue);
      expect(
        viewModel.cart.last.integration!.testMode,
        isFalse,
        reason: 'only what was added in test mode says so',
      );
    });

    test('keeps the mark through a held invoice, and a new price', () async {
      final viewModel = await open();
      viewModel.addServiceLine(
        quote: airtime,
        variantId: 9301,
        title: 'شحن',
        testMode: true,
      );
      final line = viewModel.cart.single;

      final restored = CartLine.fromJson(
        (jsonDecode(jsonEncode(line.toJson())) as Map).cast<String, Object?>(),
      );
      final requoted = restored.integration!.requoted(
        subscriberRef: '+22370123456',
        optionCode: 'air:289:5000:XOF',
        optionLabel: 'x',
        quote: 'sealed-2',
        quotedAt: DateTime.now(),
      );

      expect(restored.integration!.testMode, isTrue);
      expect(requoted.testMode, isTrue);
    });

    test('keeps the mark to itself: the server is never sent it', () async {
      final viewModel = await open();
      viewModel.addServiceLine(
        quote: airtime,
        variantId: 9301,
        title: 'شحن',
        testMode: true,
      );

      await viewModel.checkoutCurrentSale(
        payments: const [
          SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 96.5),
        ],
      );

      final lines = (sales.captured!.toJson()['lines']! as List)
          .cast<Map<String, Object?>>();
      expect(
        (lines.single['integration']! as Map).containsKey('test_mode'),
        isFalse,
      );
    });

    test('round-trips through its own JSON', () {
      final line = CartLine.create(
        variant: const ProductVariant(
          id: 9301,
          productId: 0,
          sku: '',
          unitPrice: 96.5,
          productName: 'شحن مباشر',
          isService: true,
        ),
        quantity: 1,
        integration: const CartLineIntegration(
          provider: 'pointy',
          subscriberRef: '+22370123456',
          optionCode: 'air:289:5000:XOF',
          optionLabel: 'x',
          quote: 'sealed',
        ),
      );

      final restored = CartLine.fromJson(
        (jsonDecode(jsonEncode(line.toJson())) as Map).cast<String, Object?>(),
      );

      expect(restored.integration!.isAirtime, isTrue);
      expect(restored.isDirectService, isTrue);
      expect(restored.integration!.quote, 'sealed');
    });
  });

  group('checkout', () {
    test('sends the line in the shape the server reads', () async {
      final viewModel = await open();
      viewModel.addServiceLine(quote: airtime, variantId: 9301, title: 'شحن');
      viewModel.addServiceLine(quote: bill, variantId: 9302, title: 'فاتورة');

      await viewModel.checkoutCurrentSale(
        payments: const [
          SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 132.5),
        ],
      );

      final lines = (sales.captured!.toJson()['lines']! as List)
          .cast<Map<String, Object?>>();
      expect(lines, hasLength(2));
      expect(lines.first['variant'], 9301);
      expect(lines.first['quantity'], '1');
      expect(lines.first['integration'], {
        'provider': 'pointy',
        'subscriber_ref': '+22370123456',
        'option_code': 'air:289:5000:XOF',
        'option_label': 'أورنج مالي · 5,000 فرنك أفريقي',
        'quote': 'sealed.air:289:5000:XOF.96.50',
        'months': 0,
        'package_id': '',
        'package_name': '',
      });
      expect(lines.last['variant'], 9302);
      expect(
        (lines.last['integration']! as Map)['option_code'],
        'bill:5:5000:NGN',
      );
    });

    test('previews its discounts with the same sealed quote', () async {
      final viewModel = await open();
      viewModel.addServiceLine(quote: airtime, variantId: 9301, title: 'شحن');
      await settle();

      final lines = (sales.previewed!.toJson()['lines']! as List)
          .cast<Map<String, Object?>>();
      expect(
        (lines.single['integration']! as Map)['quote'],
        'sealed.air:289:5000:XOF.96.50',
      );
    });

    test('prints the receipt, whatever the shop\'s floor says', () async {
      final plain = await open();
      plain.addVariant(
        const ProductVariant(id: 5, productId: 5, sku: 'B', unitPrice: 1),
      );
      final plainOutcome = await plain.checkoutCurrentSale(
        payments: const [
          SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 1),
        ],
      );
      expect(plainOutcome.printStatus, InvoicePrintStatus.notRequested);

      final service = await open();
      service.addServiceLine(quote: airtime, variantId: 9301, title: 'شحن');
      final serviceOutcome = await service.checkoutCurrentSale(
        payments: const [
          SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 96.5),
        ],
      );

      // Not asked for — and it was: with no printer here it could not print.
      expect(
        serviceOutcome.printStatus,
        isNot(InvoicePrintStatus.notRequested),
      );
    });
  });
}

class _EmptyCatalog extends CatalogRepository {
  _EmptyCatalog() : super(PosApiService());

  @override
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
    bool bypassCache = false,
  }) async => const Ok(ProductPage(products: <Product>[], hasMore: false));
}

class _OpenRegister extends RegisterSessionRepository {
  _OpenRegister() : super(PosApiService());

  @override
  Future<Result<RegisterSession?>> loadCurrentSession() async => const Ok(
    RegisterSession(
      id: 2,
      sessionNumber: 'RS-2',
      status: 'open',
      openingCash: 100,
    ),
  );
}

class _CapturingSales extends SaleRepository {
  _CapturingSales() : super(PosApiService());

  SaleCheckoutDraft? captured;
  SaleDiscountPreviewDraft? previewed;
  bool holdCheckout = false;
  final List<void Function()> _held = [];

  void release() {
    for (final release in _held) {
      release();
    }
    _held.clear();
  }

  @override
  Future<Result<SaleDiscountPreview>> previewDiscounts(
    SaleDiscountPreviewDraft draft,
  ) async {
    previewed = draft;
    var subtotal = 0.0;
    for (final line in draft.lines) {
      final price = RegExp(
        r'(\d+\.\d{2})$',
      ).firstMatch(line.integration?.quote ?? '')?.group(1);
      subtotal += double.tryParse(price ?? '') ?? 1;
    }
    return Ok(
      SaleDiscountPreview(
        subtotal: subtotal,
        discountTotal: 0,
        total: subtotal,
      ),
    );
  }

  @override
  Future<Result<Map<int, double>>> loadLineCosts(List<int> variantIds) async =>
      const Ok({});

  @override
  Future<Result<SaleOrder>> checkout(
    SaleCheckoutDraft draft, {
    String? idempotencyKey,
  }) async {
    captured = draft;
    if (holdCheckout) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return Ok(
      SaleOrder(
        id: 100,
        status: 'paid',
        lines: const [],
        payments: const [],
        subtotal: 0,
        total: 0,
        receiptNumber: 'R-100',
      ),
    );
  }
}
