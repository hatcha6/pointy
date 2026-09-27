import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/data/models/integration_recent_search.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/voucher_availability.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/integration_recharge_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/integration_recharge_screen.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_voucher_picker_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// A cashier's till is told prices, never what a top-up costs the agency.
///
/// Since 2026-09-26 the server leaves every cost-bearing key out for a reader
/// outside the reporting roles. These pin the till's half of that: a missing
/// cost stays missing instead of becoming a zero, the float warning still
/// works from the server's own answer, and a sale carries the sealed quote the
/// lookup handed out rather than a cost the till was never given.
void main() {
  group("a cashier's card lookup", () {
    test('has no cost, and keeps the quote and the float answer', () {
      final snapshot = IntegrationCardSnapshot.fromJson(_cashierCard());
      final year = snapshot.offers.last;

      expect(year.cost, isNull, reason: 'absent, not zero');
      expect(year.price, 240);
      expect(year.exceedsFloat, isTrue);
      expect(year.quote, 'sealed-renew-12');
      expect(snapshot.subscriber!.lifetimeSpend, isNull);
      expect(snapshot.subscriber!.purchaseCount, 6);
    });

    test('the cart line carries the quote to checkout, and no cost', () {
      final offer = IntegrationCardSnapshot.fromJson(
        _cashierCard(),
      ).offers.last;
      final line = CartLineIntegration.fromRecharge(
        IntegrationRechargeDraft(
          provider: IntegrationProviderKey.hdbox,
          serviceVariant: _serviceVariant,
          subscriberRef: '210906803499',
          offer: offer,
          price: offer.price,
        ),
      );

      final json = line.toJson();
      expect(json['quote'], 'sealed-renew-12');
      expect(json.containsKey('cost'), isFalse);
      expect(json['option_code'], 'renew:12');
    });

    test('the float warning follows the server, not the price', () async {
      final viewModel = _viewModel();
      await viewModel.lookup('210906803499');

      // 30 is under the float of 100, and the server says it is covered.
      viewModel.selectOffer(viewModel.sellableOffers.first);
      expect(viewModel.exceedsBalance, isFalse);
      // The year is priced 240 and the server says the float cannot pay it.
      viewModel.selectOffer(viewModel.sellableOffers.last);
      expect(viewModel.exceedsBalance, isTrue);
    });
  });

  group('a held invoice', () {
    test('from before quotes were sealed still carries its cost', () {
      final line = CartLineIntegration.fromJson({
        'provider': 'hdbox',
        'subscriber_ref': '210906803499',
        'option_code': 'renew:1',
        'option_label': '1 month',
        'cost': 25,
        'months': 1,
      });

      expect(line.cost, 25);
      expect(line.quote, isNull);
      expect(line.toJson()['cost'], 25);
      expect(line.toJson().containsKey('quote'), isFalse);
    });

    test('keeps its quote and invents no cost when read back', () {
      const held = CartLineIntegration(
        provider: 'hdbox',
        subscriberRef: '210906803499',
        optionCode: 'renew:12',
        optionLabel: '12 month',
        quote: 'sealed-renew-12',
        months: 12,
      );

      final restored = CartLineIntegration.fromJson(held.toJson());

      expect(restored.quote, 'sealed-renew-12');
      expect(restored.cost, isNull);
    });
  });

  group('an amount the cashier typed', () {
    // LNET's open amount, as a cashier is sent it: no commission ratio, and
    // a pricing rule of plain face value.
    final openAmount = IntegrationOpenAmount.fromJson({
      'minimum': '1',
      'maximum': null,
      'step': '1',
      'price_per_unit': '1',
      'price_fixed': '0',
    });

    test('has no cost without the commission, and is still priced', () {
      final offer = openAmount.offerFor(45);

      expect(openAmount.costRatio, isNull);
      expect(offer.cost, isNull);
      expect(offer.price, 45);
      expect(offer.exceedsFloat, isNull, reason: 'nobody quoted it');
    });

    test(
      'is warned about on its face value, which never undercounts',
      () async {
        // Face value is what the customer pays onto the line, and the float
        // pays a share of it — so this warns a little early, never late.
        final viewModel = _viewModel(
          card: _cashierCard(balance: '44.00', openAmount: true),
        );
        await viewModel.lookup('alhussainbasheir');

        viewModel.setCustomAmount(45);
        expect(viewModel.selectedOffer!.cost, isNull);
        expect(viewModel.exceedsBalance, isTrue);
        viewModel.setCustomAmount(40);
        expect(viewModel.exceedsBalance, isFalse);
      },
    );
  });

  group("a provider's card shelf", () {
    // The picker's live answer, as a cashier is sent it.
    final availability = VoucherAvailability.fromJson({
      'ok': true,
      'balance': '50.00',
      'cards': [
        {
          'variant_id': 1,
          'label': '10 دينار',
          'price': '10.00',
          'exceeds_float': false,
          'is_available': true,
        },
        {
          'variant_id': 3,
          'label': '100 دينار',
          'price': '100.00',
          'exceeds_float': true,
          'is_available': true,
        },
      ],
    });

    test('warns from the server without the cost', () {
      final hundred = availability.cardFor(3)!;
      expect(hundred.cost, isNull);
      expect(hundred.beyondFloat(availability.balance), isTrue);
      expect(
        availability.cardFor(1)!.beyondFloat(availability.balance),
        isFalse,
      );
    });

    testWidgets('flags the card the float cannot pay for', (tester) async {
      const product = Product(
        id: 30,
        name: 'ليبيانا',
        quantityOnHand: 0,
        isService: true,
        isSystem: true,
        systemKind: ProductSystemKind.voucher,
      );
      ProductVariant card(int id, String label, double price) => ProductVariant(
        id: id,
        productId: 30,
        productName: 'ليبيانا',
        displayName: label,
        fullName: 'ليبيانا - $label',
        sku: 'QRB-$id',
        unitPrice: price,
        isService: true,
      ).copyWith(productDetail: product);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: PointyTheme.light(),
          home: Scaffold(
            body: PosVoucherPicker(
              product: product,
              variants: [card(1, '10 دينار', 10), card(3, '100 دينار', 100)],
              checkAvailability: () async => availability,
              onPicked: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('يتجاوز رصيد الوكالة'), findsOneWidget);
    });
  });

  group('the screen', () {
    testWidgets('warns about the float without naming a cost', (tester) async {
      final viewModel = _viewModel();
      await tester.pumpWidget(_harness(viewModel));
      await viewModel.lookup('210906803499');
      await tester.pumpAndSettle();

      viewModel.selectOffer(viewModel.sellableOffers.last);
      await tester.pumpAndSettle();

      expect(find.textContaining('قد لا يغطّي هذا الشحن'), findsOneWidget);
      expect(find.textContaining('100.00'), findsWidgets);
      // The agency's price for a year is nowhere on the screen.
      expect(find.textContaining('220'), findsNothing);
    });

    testWidgets('says how often a card was topped up, not what agencies paid', (
      tester,
    ) async {
      final viewModel = _viewModel();
      await tester.pumpWidget(_harness(viewModel));
      await viewModel.lookup('210906803499');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('6 عمليات شحن لدى كل الوكلاء'),
        findsOneWidget,
      );
      expect(find.textContaining('750'), findsNothing);
    });
  });
}

const _serviceVariant = IntegrationServiceVariant(
  id: 9001,
  productId: 4001,
  sku: 'INTEG-HDBOX',
  name: 'شحن اشتراك HD Box',
);

/// A card lookup exactly as the server answers a cashier: prices, the float,
/// a flag per offer, a sealed quote — and no cost anywhere.
Map<String, Object?> _cashierCard({
  String balance = '100.00',
  bool openAmount = false,
}) {
  return {
    'ok': true,
    'card': {
      'card_no': '210906803499',
      'status': 'On hold',
      'status_id': 6,
      'package_name': 'HDBOX Full package',
    },
    'subscriber': {
      'subscriber_ref': '210906803499',
      'device_model': 'R-10000 Plus',
      'purchase_count': 6,
      'is_identified': false,
    },
    'offers': [
      {
        'code': 'renew:1',
        'kind': 'renew',
        'label': '1 month',
        'price': '30.00',
        'months': 1,
        'exceeds_float': false,
        'quote': 'sealed-renew-1',
      },
      {
        'code': 'renew:12',
        'kind': 'renew',
        'label': '12 month',
        'price': '240.00',
        'months': 12,
        'exceeds_float': true,
        'quote': 'sealed-renew-12',
      },
    ],
    if (openAmount)
      'open_amount': {
        'minimum': '1',
        'maximum': null,
        'step': '1',
        'price_per_unit': '1',
        'price_fixed': '0',
      },
    'service_variant': {
      'id': 9001,
      'product_id': 4001,
      'sku': 'INTEG-HDBOX',
      'name': 'شحن اشتراك HD Box',
    },
    'currency': 'LYD',
    'balance': balance,
    'history_kinds': ['purchases', 'statuses'],
  };
}

IntegrationRechargeViewModel _viewModel({Map<String, Object?>? card}) {
  return IntegrationRechargeViewModel(
    repository: _CashierRepo(card ?? _cashierCard()),
    provider: IntegrationProviderKey.hdbox,
  );
}

Widget _harness(IntegrationRechargeViewModel viewModel) {
  return MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: IntegrationRechargeScreen(viewModel: viewModel),
  );
}

class _CashierRepo extends IntegrationsRepository {
  _CashierRepo(this.card) : super(PosApiService());

  final Map<String, Object?> card;

  @override
  Future<Result<IntegrationRecentSearchPage>> loadRecentSearches({
    required String providerKey,
    String search = '',
    String? cursor,
  }) async =>
      Ok(const IntegrationRecentSearchPage(searches: [], hasMore: false));

  @override
  Future<Result<IntegrationCardSnapshot>> lookupCard({
    required String providerKey,
    required String cardNo,
    String searchBy = '',
  }) async => Ok(IntegrationCardSnapshot.fromJson(card));

  @override
  Future<Result<IntegrationHistoryPage>> loadHistory({
    required String providerKey,
    required String cardNo,
    required IntegrationHistoryKind kind,
    int limit = 10,
    int offset = 0,
  }) async => Ok(IntegrationHistoryPage(ok: true, kind: kind));
}
