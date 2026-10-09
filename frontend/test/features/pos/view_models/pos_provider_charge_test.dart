import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/service_kinds.dart';
import 'package:pointy_frontend/src/data/models/service_quote.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';

/// A sale that sold a provider's line — airtime, a bill, a card — is paid
/// first and performed after: the provider is asked once the sale is recorded.
/// When that call cannot be made the sale still stands, but the cashier must
/// never be left believing nothing is pending behind it.
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

  late _Sales sales;
  late _Integrations integrations;

  Future<PosViewModel> open() async {
    sales = _Sales();
    integrations = _Integrations();
    final viewModel = PosViewModel(
      _Catalog(),
      _Register(),
      sales,
      ShopSettingsRepository(PosApiService()),
      PrintingRepository(PosApiService()),
      integrationsRepository: integrations,
      sessionStorage: MemoryScopedJsonStorage(),
      chargeRetryDelay: Duration.zero,
    );
    addTearDown(viewModel.dispose);
    await viewModel.loadCurrentRegisterSession();
    await viewModel.resumeRegisterSession();
    viewModel.addServiceLine(quote: airtime, variantId: 9301, title: 'شحن');
    return viewModel;
  }

  Future<SaleCheckoutOutcome> pay(PosViewModel viewModel) =>
      viewModel.checkoutCurrentSale(
        payments: const [
          SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 96.5),
        ],
      );

  IntegrationChargeResult charged() => const IntegrationChargeResult(
    fulfillment: 1,
    orderLine: 7,
    provider: 'pointy',
    kind: 'airtime',
    subscriberRef: '+22370123456',
    optionLabel: 'أورنج مالي · 5,000 فرنك أفريقي',
    outcome: 'charged',
    status: 'confirmed',
  );

  test('asks the provider once the sale is recorded', () async {
    final viewModel = await open();
    integrations.answers = [
      Ok([charged()]),
    ];

    final outcome = await pay(viewModel);

    expect(integrations.chargeCalls, 1);
    expect(outcome.recharges.single.isCharged, isTrue);
  });

  test('asks again, once, when the call could not be made', () async {
    final viewModel = await open();
    integrations.answers = [
      Error(Exception('connection reset')),
      Ok([charged()]),
    ];

    final outcome = await pay(viewModel);

    expect(integrations.chargeCalls, 2);
    expect(outcome.isSuccess, isTrue);
    expect(outcome.recharges.single.isCharged, isTrue);
  });

  test(
    'says the result is unknown for every provider line when it never answers',
    () async {
      final viewModel = await open();
      integrations.answers = [
        Error(Exception('timeout')),
        Error(Exception('timeout')),
      ];

      final outcome = await pay(viewModel);

      expect(integrations.chargeCalls, 2, reason: 'once more, and no more');
      expect(outcome.isSuccess, isTrue, reason: 'the sale stands');
      final row = outcome.recharges.single;
      expect(row.outcome, 'unknown');
      expect(row.isCharged, isFalse);
      expect(row.needsAttention, isTrue, reason: 'opens the unknown dialog');
      expect(row.errorCode, 'indeterminate');
      expect(row.kind, 'airtime');
      expect(row.subscriberRef, '+22370123456');
      expect(row.optionLabel, 'أورنج مالي · 5,000 فرنك أفريقي');
      expect(row.orderLine, 7);
    },
  );

  test(
    'a retry that finds nothing left to perform is no answer either',
    () async {
      // The first call may have reached the server and been performed; only its
      // reply was lost. "Nothing to do" the second time does not say which.
      final viewModel = await open();
      integrations.answers = [Error(Exception('reset')), const Ok([])];

      final outcome = await pay(viewModel);

      expect(outcome.recharges.single.needsAttention, isTrue);
      expect(outcome.recharges.single.outcome, 'unknown');
    },
  );

  test(
    'an answer that names no rows at the first call is left as it is',
    () async {
      final viewModel = await open();
      integrations.answers = [const Ok([])];

      final outcome = await pay(viewModel);

      expect(integrations.chargeCalls, 1);
      expect(outcome.recharges, isEmpty);
    },
  );

  test('a sale with nothing for a provider never asks one', () async {
    final viewModel = await open();
    sales.provider = false;

    await pay(viewModel);

    expect(integrations.chargeCalls, 0);
  });

  test('the till stays busy while the provider is being asked', () async {
    final viewModel = await open();
    final release = Completer<void>();
    integrations
      ..hold = release.future
      ..answers = [
        Ok([charged()]),
      ];

    final checkout = pay(viewModel);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(viewModel.isCheckingOut, isTrue);
    expect(viewModel.isChargingProviders, isTrue);
    expect(viewModel.providerChargeStartedAt, isNotNull);
    expect(
      viewModel.addServiceLine(quote: airtime, variantId: 9301, title: 'x'),
      isFalse,
      reason: 'no new line while one is being performed',
    );

    release.complete();
    final outcome = await checkout;

    expect(outcome.recharges.single.isCharged, isTrue);
    expect(viewModel.isCheckingOut, isFalse);
    expect(viewModel.isChargingProviders, isFalse);
    expect(viewModel.providerChargeStartedAt, isNull);
  });

  test('is free again even when the provider call throws', () async {
    final viewModel = await open();
    integrations.answers = [Error(Exception('a')), Error(Exception('b'))];

    await pay(viewModel);

    expect(viewModel.isCheckingOut, isFalse);
    expect(viewModel.isChargingProviders, isFalse);
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

  /// Whether the order that comes back has a provider's line in it.
  bool provider = true;

  @override
  Future<Result<SaleDiscountPreview>> previewDiscounts(
    SaleDiscountPreviewDraft draft,
  ) async => const Ok(
    SaleDiscountPreview(subtotal: 96.5, discountTotal: 0, total: 96.5),
  );

  @override
  Future<Result<Map<int, double>>> loadLineCosts(List<int> variantIds) async =>
      const Ok({});

  @override
  Future<Result<SaleOrder>> checkout(
    SaleCheckoutDraft draft, {
    String? idempotencyKey,
  }) async => Ok(
    SaleOrder(
      id: 100,
      status: 'paid',
      lines: [
        SaleOrderLine(
          id: 7,
          productId: 1,
          variantId: 9301,
          quantity: 1,
          returnedQuantity: 0,
          returnableQuantity: 1,
          unitPrice: 96.5,
          total: 96.5,
          integration: provider
              ? const SaleLineIntegration(
                  provider: 'pointy',
                  kind: 'airtime',
                  subscriberRef: '+22370123456',
                  optionLabel: 'أورنج مالي · 5,000 فرنك أفريقي',
                )
              : null,
        ),
      ],
      payments: const [],
      subtotal: 96.5,
      total: 96.5,
      receiptNumber: 'R-100',
    ),
  );
}

class _Integrations extends IntegrationsRepository {
  _Integrations() : super(PosApiService());

  /// What each call to charge answers, in turn; the last is repeated.
  List<Result<List<IntegrationChargeResult>>> answers = const [];
  Future<void>? hold;
  int chargeCalls = 0;

  @override
  Future<Result<List<IntegrationChargeResult>>> charge({
    int? orderId,
    int? fulfillmentId,
  }) async {
    final index = chargeCalls < answers.length
        ? chargeCalls
        : answers.length - 1;
    chargeCalls++;
    await hold;
    return answers[index];
  }
}
