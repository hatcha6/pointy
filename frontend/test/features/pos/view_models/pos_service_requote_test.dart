import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/services_fake_repository.dart';
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

/// A service line is priced by a quote, and a quote does not last: a held
/// invoice that waits an hour holds a price from an hour ago. Before the sale
/// is paid — and when a held invoice comes back — every service line is priced
/// again, and a price that moved, or an offer that is gone, is put in front of
/// the cashier instead of being charged or refused behind their back.
void main() {
  late PreviewServicesRepository relay;
  late MemoryScopedJsonStorage storage;

  ServiceQuote quoteOf({
    double price = 96.5,
    String phone = '+22370123456',
    String code = 'air:289:5000:XOF',
  }) => ServiceQuote(
    kind: ServiceKind.airtime,
    optionCode: code,
    optionLabel: 'أورنج مالي · 5,000 فرنك أفريقي',
    subscriberRef: phone,
    price: price,
    receiveAmount: '5000',
    receiveCurrency: 'XOF',
    quote: 'sealed.$code.${price.toStringAsFixed(2)}',
    serviceVariantId: 9301,
    request: const ServiceQuoteRequest.airtime(
      country: 'ML',
      operatorId: 289,
      phone: '70123456',
      amount: '5000',
      amountCurrency: 'XOF',
    ),
  );

  PosViewModel build({
    Duration freshFor = const Duration(minutes: 2),
    MemoryScopedJsonStorage? sharedStorage,
  }) {
    final viewModel = PosViewModel(
      _Catalog(),
      _Register(),
      _Sales(),
      ShopSettingsRepository(PosApiService()),
      PrintingRepository(PosApiService()),
      integrationsRepository: relay,
      sessionStorage: sharedStorage ?? storage,
      serviceQuoteFreshFor: freshFor,
    );
    addTearDown(viewModel.dispose);
    return viewModel;
  }

  Future<PosViewModel> open({
    Duration freshFor = const Duration(minutes: 2),
  }) async {
    final viewModel = build(freshFor: freshFor);
    await viewModel.loadCurrentRegisterSession();
    await viewModel.resumeRegisterSession();
    return viewModel;
  }

  Future<void> settle([int milliseconds = 60]) =>
      Future<void>.delayed(Duration(milliseconds: milliseconds));

  setUp(() {
    relay = PreviewServicesRepository();
    storage = MemoryScopedJsonStorage();
  });

  group('a line is priced again', () {
    test('and nothing is said when the price has not moved', () async {
      final viewModel = await open(freshFor: Duration.zero);
      viewModel.addServiceLine(quote: quoteOf(), variantId: 9301, title: 'شحن');
      final before = viewModel.cart.single.integration!;

      final changes = await viewModel.requoteServiceLines();

      expect(changes, isEmpty);
      expect(relay.quotes, hasLength(1));
      expect(relay.quotes.single.phone, '70123456', reason: 'the same request');
      expect(relay.quotes.single.country, 'ML');
      expect(relay.quotes.single.operatorId, 289);
      final after = viewModel.cart.single.integration!;
      expect(
        after.quotedAt!.isAfter(before.quotedAt!) ||
            after.quotedAt == before.quotedAt,
        isTrue,
      );
      expect(viewModel.cart.single.unitPrice, 96.5);
    });

    test(
      'and a price that moved is proposed, never applied by itself',
      () async {
        final viewModel = await open(freshFor: Duration.zero);
        viewModel.addServiceLine(
          quote: quoteOf(),
          variantId: 9301,
          title: 'شحن',
        );
        relay.quotePrice = 99;

        final changes = await viewModel.requoteServiceLines();

        expect(changes, hasLength(1));
        final change = changes.single;
        expect(change.isRefused, isFalse);
        expect(change.oldPrice, 96.5);
        expect(change.newPrice, 99);
        expect(viewModel.cart.single.unitPrice, 96.5, reason: 'not yet');
      },
    );

    test('accepting the new price replaces the line, quote and all', () async {
      final viewModel = await open(freshFor: Duration.zero);
      viewModel.addServiceLine(quote: quoteOf(), variantId: 9301, title: 'شحن');
      final key = viewModel.cart.single.lineKey;
      relay.quotePrice = 99;
      final change = (await viewModel.requoteServiceLines()).single;

      viewModel.acceptServiceRequote(change);

      expect(viewModel.cart, hasLength(1));
      final line = viewModel.cart.single;
      expect(line.lineKey, key, reason: 'the same line');
      expect(line.unitPrice, 99);
      expect(line.integration!.quote, change.quote!.quote);
      expect(viewModel.subtotal, 99);
      // …and it is fresh again, so it is not asked a second time.
      expect(line.integration!.quotedAt, isNotNull);
    });

    test(
      'an offer that is gone is said so, and the line can be dropped',
      () async {
        final viewModel = await open(freshFor: Duration.zero);
        viewModel.addServiceLine(
          quote: quoteOf(),
          variantId: 9301,
          title: 'شحن',
        );
        relay.refuseQuote = ServiceRefusalCode.amountNotOffered;

        final changes = await viewModel.requoteServiceLines();

        final change = changes.single;
        expect(change.isRefused, isTrue);
        expect(change.refusal!.errorCode, ServiceRefusalCode.amountNotOffered);
        expect(change.newPrice, isNull);
        expect(viewModel.cart, hasLength(1), reason: 'not removed by itself');

        viewModel.dropServiceRequote(change);

        expect(viewModel.cart, isEmpty);
      },
    );

    test('a server that cannot be asked changes nothing', () async {
      final viewModel = await open(freshFor: Duration.zero);
      viewModel.addServiceLine(quote: quoteOf(), variantId: 9301, title: 'شحن');
      relay.failQuote = true;

      final changes = await viewModel.requoteServiceLines();

      expect(changes, isEmpty);
      expect(viewModel.cart.single.unitPrice, 96.5);
    });

    test('a refusal that may pass is not taken for a gone offer', () async {
      final viewModel = await open(freshFor: Duration.zero);
      viewModel.addServiceLine(quote: quoteOf(), variantId: 9301, title: 'شحن');
      relay.refuseQuote = ServiceRefusalCode.unreachable;

      expect(await viewModel.requoteServiceLines(), isEmpty);
    });

    test('a line priced a moment ago is not asked about', () async {
      final viewModel = await open();
      viewModel.addServiceLine(quote: quoteOf(), variantId: 9301, title: 'شحن');

      final changes = await viewModel.requoteServiceLines();

      expect(changes, isEmpty);
      expect(relay.quotes, isEmpty);
    });

    test(
      'a line that kept no request is left to the server\'s own check',
      () async {
        final viewModel = await open(freshFor: Duration.zero);
        final bare = ServiceQuote(
          kind: ServiceKind.airtime,
          optionCode: 'air:289:5000:XOF',
          optionLabel: 'x',
          subscriberRef: '+22370123456',
          price: 96.5,
          receiveAmount: '5000',
          receiveCurrency: 'XOF',
          quote: 'sealed',
          serviceVariantId: 9301,
        );
        viewModel.addServiceLine(quote: bare, variantId: 9301, title: 'شحن');
        relay.quotePrice = 120;

        expect(await viewModel.requoteServiceLines(), isEmpty);
        expect(relay.quotes, isEmpty);
      },
    );

    test('cards and other lines are never asked', () async {
      final viewModel = await open(freshFor: Duration.zero);
      viewModel.addVariant(
        const ProductVariant(id: 5, productId: 5, sku: 'B', unitPrice: 1),
      );

      expect(await viewModel.requoteServiceLines(), isEmpty);
      expect(relay.quotes, isEmpty);
    });
  });

  group('the request travels with a held line', () {
    test(
      'and so does the time it was priced, but neither goes to the server',
      () async {
        final viewModel = await open();
        viewModel.addServiceLine(
          quote: quoteOf(),
          variantId: 9301,
          title: 'شحن',
        );

        final stored =
            jsonDecode(jsonEncode(viewModel.cart.single.toJson()))
                as Map<String, Object?>;
        final integration = stored['integration']! as Map<String, Object?>;
        expect(integration['quoted_at'], isNotNull);
        expect((integration['quote_request']! as Map)['country'], 'ML');
        expect((integration['quote_request']! as Map)['phone'], '70123456');

        final wire = viewModel.cart.single.integration!.toJson();
        expect(wire.containsKey('quoted_at'), isFalse);
        expect(wire.containsKey('quote_request'), isFalse);

        final restored = CartLine.fromJson(stored);
        expect(restored.integration!.quoteRequest!['operator_id'], 289);
        expect(
          ServiceQuoteRequest.fromJson(
            restored.integration!.quoteRequest!,
          ).signature,
          quoteOf().request!.signature,
        );
      },
    );
  });

  group('a held invoice that comes back', () {
    test(
      'has its service lines priced again, and a moved price queued',
      () async {
        final first = build();
        await first.loadCurrentRegisterSession();
        await first.resumeRegisterSession();
        await first.restorePersistedSessions('user-1');
        first.addServiceLine(quote: quoteOf(), variantId: 9301, title: 'شحن');
        await settle(700);
        relay.quotePrice = 99;

        final second = build(freshFor: Duration.zero);
        await second.loadCurrentRegisterSession();
        await second.resumeRegisterSession();
        await second.restorePersistedSessions('user-1');
        await settle();

        expect(second.cart, hasLength(1));
        expect(second.serviceRequotes.hasPending, isTrue);
        final change = second.serviceRequotes.take().single;
        expect(change.newPrice, 99);
        expect(second.serviceRequotes.hasPending, isFalse);
      },
    );

    test('switched back to, is priced again the same way', () async {
      final viewModel = await open(freshFor: Duration.zero);
      viewModel.addServiceLine(quote: quoteOf(), variantId: 9301, title: 'شحن');
      final heldId = viewModel.saleSessions.first.id;
      viewModel.startNewSaleSession();
      relay.quotePrice = 99;

      viewModel.switchSaleSession(heldId);
      await settle();

      expect(viewModel.serviceRequotes.take().single.newPrice, 99);
    });
  });
}

class _Catalog extends CatalogRepository {
  _Catalog() : super(PosApiService());

  @override
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
    bool bypassCache = false,
  }) async => const Ok(ProductPage(products: <Product>[], hasMore: false));
}

class _Register extends RegisterSessionRepository {
  _Register() : super(PosApiService());

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

class _Sales extends SaleRepository {
  _Sales() : super(PosApiService());

  @override
  Future<Result<SaleDiscountPreview>> previewDiscounts(
    SaleDiscountPreviewDraft draft,
  ) async {
    var subtotal = 0.0;
    for (final line in draft.lines) {
      final price = RegExp(
        r'(\d+\.\d{2})$',
      ).firstMatch(line.integration?.quote ?? '')?.group(1);
      subtotal += (double.tryParse(price ?? '') ?? 1) * line.quantity;
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
}
