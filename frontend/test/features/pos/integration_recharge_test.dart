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

      expect(viewModel.sellableOffers, hasLength(2));
      expect(viewModel.sellableOffers.every((o) => o.isRenewal), isTrue);
      expect(
        viewModel.snapshot!.offers.any((o) => !o.isRenewal && !o.isTopUp),
        isTrue,
        reason: 'the fixture still contains one, and it must stay hidden',
      );
    });
  });

  group('the draft handed to the cart', () {
    test('carries the quoted cost and the server-quoted price', () async {
      final viewModel = _viewModel(_FakeRepo());
      await viewModel.lookup('12345');
      viewModel.selectOffer(viewModel.sellableOffers.last);

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
      viewModel.selectOffer(viewModel.sellableOffers.first);

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

      viewModel.selectOffer(viewModel.sellableOffers.first); // 25, balance 25
      expect(viewModel.exceedsBalance, isFalse);
      viewModel.selectOffer(viewModel.sellableOffers.last); // 220
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

  group('LNET: one phone, several lines', () {
    test('a multi-line match prices nothing until a line is chosen', () async {
      // Guessing would top up somebody's dead second line and leave the one
      // they came in about still expired.
      final viewModel = _lnetViewModel(_FakeLnetRepo(manyLines: true));
      await viewModel.lookup('0910682854');

      expect(viewModel.lookupState, RechargeLookupState.found);
      expect(viewModel.needsLineSelection, isTrue);
      expect(viewModel.candidates, hasLength(3));
      expect(viewModel.sellableOffers, isEmpty);
      expect(viewModel.buildDraft(), isNull);
    });

    test('each line shows the state that tells it from the others', () async {
      final viewModel = _lnetViewModel(_FakeLnetRepo(manyLines: true));
      await viewModel.lookup('0910682854');

      final health = viewModel.candidates
          .map((line) => line.health(now: DateTime(2026, 9, 20)))
          .toList();
      expect(health, [
        IntegrationCardHealth.active,
        IntegrationCardHealth.expired,
        // Suspended is said in words, with no numeric id behind it — without
        // reading the word this line would pass for merely unknown.
        IntegrationCardHealth.locked,
      ]);
    });

    test('choosing a line re-reads it by its own identifier', () async {
      final repo = _FakeLnetRepo(manyLines: true);
      final viewModel = _lnetViewModel(repo);
      await viewModel.lookup('0910682854');
      await viewModel.selectLine(viewModel.candidates[1]);

      expect(repo.lookedUp, ['0910682854', 'basheir.shop']);
      expect(viewModel.needsLineSelection, isFalse);
      expect(viewModel.buildDraft(), isNull, reason: 'still nothing chosen');
      expect(viewModel.sellableOffers, isNotEmpty);
    });

    test('a single match needs no choosing', () async {
      final viewModel = _lnetViewModel(_FakeLnetRepo());
      await viewModel.lookup('0910682854');

      expect(viewModel.needsLineSelection, isFalse);
      expect(viewModel.sellableOffers, hasLength(2));
    });
  });

  group('LNET: an amount the buttons do not cover', () {
    test('the quick-picks are shortcuts, not the whole menu', () async {
      final viewModel = _lnetViewModel(_FakeLnetRepo());
      await viewModel.lookup('basheir.home');

      expect(viewModel.allowsCustomAmount, isTrue);
      expect(viewModel.sellableOffers.every((o) => o.isTopUp), isTrue);
    });

    test('a typed amount is priced at face value and costs 95%', () async {
      final viewModel = _lnetViewModel(_FakeLnetRepo());
      await viewModel.lookup('basheir.home');
      viewModel.setCustomAmount(37);

      final offer = viewModel.selectedOffer!;
      expect(offer.code, 'topup:37');
      expect(offer.cost, closeTo(35.15, 0.001));
      // Stored value sold below its face value loses money on every sale.
      expect(offer.price, 37);
      expect(offer.faceValue, 37);
    });

    test('a markup the shop set still lands above face value', () async {
      const spec = IntegrationOpenAmount(
        minimum: 1,
        step: 1,
        costRatio: 0.95,
        pricePerUnit: 0.95,
        priceFixed: 5,
      );
      expect(spec.priceOf(45), 47.75);
      // And a markup too small to clear face value never drops below it.
      const tiny = IntegrationOpenAmount(
        minimum: 1, step: 1, costRatio: 0.95, pricePerUnit: 0.95, priceFixed: 1,
      );
      expect(tiny.priceOf(45), 45);
    });

    test('an amount the provider would refuse selects nothing', () async {
      final viewModel = _lnetViewModel(_FakeLnetRepo());
      await viewModel.lookup('basheir.home');

      viewModel.setCustomAmount(0);
      expect(viewModel.selectedOffer, isNull);
      expect(viewModel.customAmountProblem,
          IntegrationAmountProblem.notPositive);

      viewModel.setCustomAmount(45.5);
      expect(viewModel.selectedOffer, isNull);
      expect(viewModel.customAmountProblem,
          IntegrationAmountProblem.notAMultiple);

      viewModel.setCustomAmount(45);
      expect(viewModel.customAmountProblem, isNull);
      expect(viewModel.selectedOffer, isNotNull);
    });

    test('tapping a quick-pick retires the typed amount', () async {
      // Otherwise the field keeps showing a number that is not what is sold.
      final viewModel = _lnetViewModel(_FakeLnetRepo());
      await viewModel.lookup('basheir.home');
      viewModel.setCustomAmount(37);
      viewModel.selectOffer(viewModel.sellableOffers.first);

      expect(viewModel.customAmount, isNull);
      expect(viewModel.selectedOffer!.code, 'topup:25');
    });

    test('clearing the quick-picks does not read as a broken provider', () async {
      // An owner who wants amounts typed every time gets an empty grid and a
      // working field, not a warning that the provider is down.
      final viewModel = _lnetViewModel(_FakeLnetRepo(noQuickPicks: true));
      await viewModel.lookup('basheir.home');

      expect(viewModel.sellableOffers, isEmpty);
      expect(viewModel.allowsCustomAmount, isTrue);
      viewModel.setCustomAmount(45);
      expect(viewModel.buildDraft()!.offer.code, 'topup:45');
    });

    test('a phone search addresses the line by the username it found', () async {
      // The search term and the line's identifier are different strings for
      // LNET, and everything after the search belongs to the identifier. The
      // history tab asked for the phone number, which is not what the
      // provider's payments report is keyed on — so a customer with top-ups
      // showed none, on the search a till does most.
      final repository = _FakeLnetRepo(resolvesTo: 'alhussainbasheir');
      final viewModel = _lnetViewModel(repository);
      await viewModel.lookup('0910682854');

      expect(repository.lookedUp, ['0910682854']);
      expect(repository.historyLookups, ['alhussainbasheir']);

      // And the cart line carries the same identifier the recharge is keyed
      // on, not the phone number somebody typed to find it.
      viewModel.setCustomAmount(45);
      expect(viewModel.buildDraft()!.subscriberRef, 'alhussainbasheir');
    });

    test('a typed amount reaches the cart as an ordinary line', () async {
      final viewModel = _lnetViewModel(_FakeLnetRepo());
      await viewModel.lookup('basheir.home');
      viewModel.setCustomAmount(37);

      final draft = viewModel.buildDraft()!;
      expect(draft.subscriberRef, 'basheir.home');
      expect(draft.offer.code, 'topup:37');
      expect(draft.serviceVariant.sku, 'INTEG-LNET');
    });

    test('the float warning fires on cost, not on face value', () async {
      // 45 face costs the float 42.75; a float of 43 covers it.
      final viewModel = _lnetViewModel(_FakeLnetRepo());
      await viewModel.lookup('basheir.home');
      viewModel.setCustomAmount(45);
      expect(viewModel.exceedsBalance, isFalse);

      viewModel.setCustomAmount(600);
      expect(viewModel.exceedsBalance, isTrue);
    });
  });

  group('the screen', () {
    testWidgets('always says when the top-up will actually be performed', (
      tester,
    ) async {
      // A cashier who is wrong about this tells the customer something wrong:
      // before the write path existed the danger was believing a dead box was
      // live, and now it is not knowing the result is still to come. Either
      // way the screen has to say it every time, not once in a tooltip.
      final viewModel = _viewModel(_FakeRepo());
      await tester.pumpWidget(_harness(viewModel));
      await viewModel.lookup('12345');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('يُنفَّذ الشحن لدى المزوّد مباشرة'),
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

      viewModel.selectOffer(viewModel.sellableOffers.first);
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

const _lnetServiceVariant = IntegrationServiceVariant(
  id: 9002,
  productId: 4002,
  sku: 'INTEG-LNET',
  name: 'شحن اشتراك LNET',
);

/// The 5% agency commission, as the backend quotes it.
const _lnetOpenAmount = IntegrationOpenAmount(
  minimum: 1,
  step: 1,
  costRatio: 0.95,
  pricePerUnit: 0.95,
);

IntegrationCardInfo _lnetLine(
  String username, {
  required String status,
  DateTime? expireAt,
  String package = 'Unlimited Home Basic',
}) {
  return IntegrationCardInfo(
    cardNo: username,
    status: status,
    expireAt: expireAt,
    packageName: package,
    providerId: '214737',
  );
}

class _FakeLnetRepo extends IntegrationsRepository {
  _FakeLnetRepo({
    this.manyLines = false,
    this.noQuickPicks = false,
    this.resolvesTo,
  }) : super(PosApiService());

  /// When true the first lookup matches three lines, as one phone number can.
  final bool manyLines;

  /// When true the shop has cleared its quick-pick amounts.
  final bool noQuickPicks;

  /// The username a search resolves to, when it is not the search term
  /// itself — a phone lookup answers with the line's own username.
  final String? resolvesTo;
  final List<String> lookedUp = [];
  final List<String> historyLookups = [];

  @override
  Future<Result<IntegrationCardSnapshot>> lookupCard({
    required String providerKey,
    required String cardNo,
  }) async {
    lookedUp.add(cardNo);
    // A phone number matches every line; a username matches only its own.
    final isPhone = manyLines && !cardNo.contains('.');
    if (isPhone) {
      return Ok(
        IntegrationCardSnapshot(
          card: const IntegrationCardInfo(cardNo: ''),
          offers: const [],
          serviceVariant: _lnetServiceVariant,
          needsSelection: true,
          candidates: [
            _lnetLine('basheir.home', status: 'Active',
                expireAt: DateTime(2026, 12, 1)),
            _lnetLine('basheir.shop', status: 'Expired',
                expireAt: DateTime(2026, 2, 2)),
            _lnetLine('basheir.old', status: 'Suspended'),
          ],
          balance: 518.8,
        ),
      );
    }
    return Ok(
      IntegrationCardSnapshot(
        card: _lnetLine(
          resolvesTo ?? cardNo,
          status: 'Active',
          expireAt: DateTime(2026, 12, 1),
        ),
        offers: noQuickPicks ? const [] : const [
          IntegrationOffer(
            code: 'topup:25',
            kind: 'topup',
            label: '25 LYD',
            cost: 23.75,
            price: 25,
            faceValue: 25,
          ),
          IntegrationOffer(
            code: 'topup:45',
            kind: 'topup',
            label: '45 LYD',
            cost: 42.75,
            price: 45,
            faceValue: 45,
          ),
        ],
        openAmount: _lnetOpenAmount,
        serviceVariant: _lnetServiceVariant,
        balance: 518.8,
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
    historyLookups.add(cardNo);
    return Ok(IntegrationHistoryPage(ok: true, kind: kind, limit: limit));
  }
}

IntegrationRechargeViewModel _lnetViewModel(IntegrationsRepository repository) {
  return IntegrationRechargeViewModel(
    repository: repository,
    provider: IntegrationProviderKey.lnet,
  );
}

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
