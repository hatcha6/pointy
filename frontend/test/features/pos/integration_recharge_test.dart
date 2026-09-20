import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/integrations_api_client.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/integration_recharge_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/integration_recharge_screen.dart';

/// The top-up flow sells something the shop cannot take back and has not yet
/// performed. These pin the parts where getting it wrong costs money or lies
/// to a customer.
void main() {
  group('lookup', () {
    test('a provider refusal is not reported as a broken request', () async {
      final viewModel = _viewModel(_FakeRepo(refusal: 'not_found'));
      await viewModel.lookup('12345');

      expect(viewModel.lookupState, RechargeLookupState.refused);
      expect(viewModel.refusalCode, 'not_found');
      expect(viewModel.failure, isNull);
    });

    test('a broken request is not reported as a missing card', () async {
      final viewModel = _viewModel(_FakeRepo(fail: true));
      await viewModel.lookup('12345');

      expect(viewModel.lookupState, RechargeLookupState.failed);
      expect(viewModel.failure, isNotNull);
      expect(viewModel.refusalCode, isEmpty);
    });

    test('nothing is preselected when a card is found', () async {
      // A preselected duration is a sale made by accident: the cashier taps
      // "add to cart" to get past the screen and has bought twelve months.
      final viewModel = _viewModel(_FakeRepo());
      await viewModel.lookup('12345');

      expect(viewModel.lookupState, RechargeLookupState.found);
      expect(viewModel.selectedOffer, isNull);
      expect(viewModel.buildDraft(), isNull);
    });

    test('a package switch is never shown, even if one arrives', () async {
      // Two locks on the same door: the backend does not send them, and the
      // till would not show one if it did. A mis-tap here puts a subscriber
      // on the wrong package and breaks their card.
      final viewModel = _viewModel(_FakeRepo());
      await viewModel.lookup('12345');

      expect(viewModel.renewalOffers, hasLength(2));
      expect(viewModel.renewalOffers.every((o) => o.isRenewal), isTrue);
      expect(
        viewModel.snapshot!.offers.any((o) => !o.isRenewal),
        isTrue,
        reason: 'the fixture still contains one, and it must stay hidden',
      );
    });
  });

  group('the draft handed to the cart', () {
    test('carries the quoted cost and the server-quoted price', () async {
      final viewModel = _viewModel(_FakeRepo());
      await viewModel.lookup('12345');
      viewModel.selectOffer(viewModel.renewalOffers.last);

      final draft = viewModel.buildDraft()!;
      expect(draft.subscriberRef, '12345');
      expect(draft.cost, 220);
      expect(draft.price, 245);
      expect(draft.margin, 25);
      expect(draft.serviceVariant.sku, 'INTEG-HDBOX');
    });

    test('the payload names the option, never the price', () async {
      // apps.sales recomputes the selling price from the shop's markup; a
      // price sent from a till would be a price a cashier could choose.
      final viewModel = _viewModel(_FakeRepo());
      await viewModel.lookup('12345');
      viewModel.selectOffer(viewModel.renewalOffers.first);

      final json = viewModel.buildDraft()!.toJson();
      expect(json['option_code'], 'renew:1');
      expect(json['cost'], 25);
      expect(json.containsKey('price'), isFalse);
    });
  });

  group('float', () {
    test('warns when the agency balance cannot cover the top-up', () async {
      final viewModel = _viewModel(_FakeRepo());
      await viewModel.lookup('12345');

      viewModel.selectOffer(viewModel.renewalOffers.first); // 25, balance 25
      expect(viewModel.exceedsBalance, isFalse);
      viewModel.selectOffer(viewModel.renewalOffers.last); // 220
      expect(viewModel.exceedsBalance, isTrue);
    });
  });

  group('history paging', () {
    test('pages forward and back against the provider count', () async {
      final repo = _FakeRepo();
      final viewModel = _viewModel(repo);
      await viewModel.lookup('12345');

      expect(viewModel.historyPage!.pageNumber, 1);
      expect(viewModel.historyPage!.hasNext, isTrue);
      expect(viewModel.historyPage!.hasPrevious, isFalse);

      await viewModel.nextHistoryPage();
      expect(viewModel.historyPage!.pageNumber, 2);
      expect(repo.lastOffset, 10);

      await viewModel.previousHistoryPage();
      expect(repo.lastOffset, 0);
    });

    test('switching tab reloads rather than showing the other list', () async {
      final repo = _FakeRepo();
      final viewModel = _viewModel(repo);
      await viewModel.lookup('12345');
      expect(viewModel.historyPage!.kind, IntegrationHistoryKind.purchases);

      await viewModel.showHistoryKind(IntegrationHistoryKind.statuses);
      expect(viewModel.historyPage!.kind, IntegrationHistoryKind.statuses);
      expect(repo.lastKind, IntegrationHistoryKind.statuses);
    });
  });

  group('the cart line', () {
    test('two top-ups never merge into one line', () {
      // Each is its own purchase from the provider, with its own cost and its
      // own confirmation — quantity two would be a single purchase of two.
      final first = _rechargeLine('111');
      final second = _rechargeLine('222');
      expect(first.lineKey, isNot(second.lineKey));
      expect(first.allowsQuantityEdit, isFalse);
      expect(second.allowsQuantityEdit, isFalse);
    });

    test('survives being persisted and restored', () {
      // Held invoices are written to disk; a restored top-up that lost its
      // card number would check out against nobody.
      final line = _rechargeLine('210906803499');
      final restored = CartLine.fromJson(line.toJson());
      expect(restored.integration!.subscriberRef, '210906803499');
      expect(restored.integration!.cost, 25);
      expect(restored.integration!.optionCode, 'renew:1');
      expect(restored.isIntegrationRecharge, isTrue);
    });
  });

  group('the screen', () {
    testWidgets('always says the top-up has not been performed yet', (
      tester,
    ) async {
      // A cashier who believes the subscription is already live will tell the
      // customer so, and the customer will go home to a dead box.
      final viewModel = _viewModel(_FakeRepo());
      await tester.pumpWidget(_harness(viewModel));
      await viewModel.lookup('12345');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('تنفيذ الشحن لدى المزوّد خطوة منفصلة'),
        findsOneWidget,
      );
    });

    testWidgets('add-to-cart stays disabled until something is chosen', (
      tester,
    ) async {
      final viewModel = _viewModel(_FakeRepo());
      await tester.pumpWidget(_harness(viewModel));
      await viewModel.lookup('12345');
      await tester.pumpAndSettle();

      // byWidgetPredicate, not byType: FilledButton.icon returns a private
      // subclass that an exact-type finder misses.
      Finder addButton() => find.ancestor(
        of: find.text('أضف إلى السلة'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );

      expect(
        tester.widget<FilledButton>(addButton()).onPressed,
        isNull,
        reason: 'nothing is chosen yet',
      );

      viewModel.selectOffer(viewModel.renewalOffers.first);
      await tester.pumpAndSettle();

      expect(tester.widget<FilledButton>(addButton()).onPressed, isNotNull);
    });

    testWidgets('a missing card is named, not shown as a generic error', (
      tester,
    ) async {
      final viewModel = _viewModel(_FakeRepo(refusal: 'not_found'));
      await tester.pumpWidget(_harness(viewModel));
      await viewModel.lookup('12345');
      await tester.pumpAndSettle();

      expect(find.text('لم يُعثر على البطاقة المطلوبة'), findsOneWidget);
    });
  });
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

IntegrationRechargeViewModel _viewModel(IntegrationsRepository repository) {
  return IntegrationRechargeViewModel(
    repository: repository,
    provider: IntegrationProviderKey.hdbox,
  );
}

CartLine _rechargeLine(String card) {
  return CartLine.create(
    variant: const ProductVariant(
      id: 9001,
      productId: 4001,
      sku: 'INTEG-HDBOX',
      unitPrice: 30,
      isService: true,
    ),
    quantity: 1,
    integration: CartLineIntegration(
      provider: 'hdbox',
      subscriberRef: card,
      optionCode: 'renew:1',
      optionLabel: '1 month',
      cost: 25,
      months: 1,
    ),
  );
}

const _serviceVariant = IntegrationServiceVariant(
  id: 9001,
  productId: 4001,
  sku: 'INTEG-HDBOX',
  name: 'شحن اشتراك HD Box',
);

class _FakeRepo extends IntegrationsRepository {
  _FakeRepo({this.refusal, this.fail = false}) : super(PosApiService());

  final String? refusal;
  final bool fail;
  int lastOffset = 0;
  IntegrationHistoryKind lastKind = IntegrationHistoryKind.purchases;

  @override
  Future<Result<IntegrationCardSnapshot>> lookupCard({
    required String providerKey,
    required String cardNo,
  }) async {
    if (fail) return Error(Exception('network down'));
    if (refusal != null) {
      return Error(IntegrationProviderRefusal(refusal!));
    }
    return Ok(
      IntegrationCardSnapshot(
        card: IntegrationCardInfo(
          cardNo: cardNo,
          status: 'On hold',
          statusId: 6,
          expireAt: DateTime(2026, 8, 1),
          packageName: 'HDBOX Full package',
        ),
        offers: const [
          IntegrationOffer(
            code: 'renew:1',
            kind: 'renew',
            label: '1 month',
            cost: 25,
            price: 30,
            months: 1,
          ),
          IntegrationOffer(
            code: 'renew:12',
            kind: 'renew',
            label: '12 month',
            cost: 220,
            price: 245,
            months: 12,
          ),
          IntegrationOffer(
            code: 'switch:1',
            kind: 'switch',
            label: 'radwan',
            cost: 5,
            price: 8,
            packageId: '1',
            packageName: 'radwan',
          ),
        ],
        serviceVariant: _serviceVariant,
        balance: 25,
      ),
    );
  }

  @override
  Future<Result<IntegrationHistoryPage>> loadHistory({
    required String providerKey,
    required String cardNo,
    required IntegrationHistoryKind kind,
    int limit = 10,
    int offset = 0,
  }) async {
    lastOffset = offset;
    lastKind = kind;
    return Ok(
      IntegrationHistoryPage(
        ok: true,
        kind: kind,
        total: 26,
        limit: limit,
        offset: offset,
        purchases: kind == IntegrationHistoryKind.purchases
            ? [
                IntegrationPurchaseEntry(
                  reference: '1',
                  cost: 25,
                  months: 1,
                  at: DateTime(2026, 6, 30),
                  operatorName: 'Alnassim',
                  isOurs: true,
                ),
              ]
            : const [],
        statuses: kind == IntegrationHistoryKind.statuses
            ? [
                IntegrationStatusEntry(
                  fromStatus: 'Active',
                  toStatus: 'On hold',
                  operatorName: 'System',
                  at: DateTime(2026, 8, 1),
                ),
              ]
            : const [],
      ),
    );
  }
}
