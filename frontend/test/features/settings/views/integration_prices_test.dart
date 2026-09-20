import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/integrations_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/integration_prices_sheet.dart';

/// The real ladder this was built for: HD Box quotes 25/65/125/220 and the
/// shop sells at 30/80/140/240 — neither a fixed amount nor a fixed
/// percentage, so every option carries its own price.
void main() {
  Widget harness(IntegrationsViewModel viewModel) {
    return MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: IntegrationPricesForm(
          viewModel: viewModel,
          providerKey: IntegrationProviderKey.hdbox,
        ),
      ),
    );
  }

  testWidgets('shows each option with the provider cost beside it', (
    tester,
  ) async {
    final viewModel = IntegrationsViewModel(_FakeRepo());
    await viewModel.loadPrices(IntegrationProviderKey.hdbox);
    await tester.pumpWidget(harness(viewModel));
    await tester.pumpAndSettle();

    expect(find.textContaining('25.00'), findsWidgets);
    expect(find.textContaining('220.00'), findsWidgets);
  });

  testWidgets('sends only the rows the owner touched', (tester) async {
    // A save must not rewrite a price somebody else changed meanwhile.
    final repo = _FakeRepo();
    final viewModel = IntegrationsViewModel(repo);
    await viewModel.loadPrices(IntegrationProviderKey.hdbox);
    await tester.pumpWidget(harness(viewModel));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '30');
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ الأسعار'));
    await tester.pumpAndSettle();

    expect(repo.saved, {'renew:1': 30.0});
  });

  testWidgets('a cleared field means "sell at cost", not "unchanged"', (
    tester,
  ) async {
    final repo = _FakeRepo(pricedFirst: true);
    final viewModel = IntegrationsViewModel(repo);
    await viewModel.loadPrices(IntegrationProviderKey.hdbox);
    await tester.pumpWidget(harness(viewModel));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ الأسعار'));
    await tester.pumpAndSettle();

    expect(repo.saved.containsKey('renew:1'), isTrue);
    expect(repo.saved['renew:1'], isNull);
  });

  testWidgets('save stays disabled until something changes', (tester) async {
    final viewModel = IntegrationsViewModel(_FakeRepo());
    await viewModel.loadPrices(IntegrationProviderKey.hdbox);
    await tester.pumpWidget(harness(viewModel));
    await tester.pumpAndSettle();

    Finder button() => find.ancestor(
      of: find.text('حفظ الأسعار'),
      matching: find.byWidgetPredicate((w) => w is FilledButton),
    );
    expect(tester.widget<FilledButton>(button()).onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, '30');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(button()).onPressed, isNotNull);
  });

  testWidgets('warns when the provider has outrun the shop price', (
    tester,
  ) async {
    // HD Box moved 12 months from 210 to 220 in the field. A shop still
    // charging the old number is losing money on every sale, silently.
    final viewModel = IntegrationsViewModel(_FakeRepo(belowCost: true));
    await viewModel.loadPrices(IntegrationProviderKey.hdbox);
    await tester.pumpWidget(harness(viewModel));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('أصبح سعر بيعها أقل من تكلفتها'),
      findsOneWidget,
    );
  });

  testWidgets('a row on the provider recommendation says so', (tester) async {
    // HD Box publishes 30/80/140/240 and every agency sells at them, so an
    // untouched row is following the card — not unpriced.
    final viewModel = IntegrationsViewModel(_FakeRepo());
    await viewModel.loadPrices(IntegrationProviderKey.hdbox);
    await tester.pumpWidget(harness(viewModel));
    await tester.pumpAndSettle();

    expect(find.textContaining('السعر الموصى به من المزوّد'), findsWidgets);
    // The field itself stays empty: the recommendation is a hint, so the row
    // keeps following the card if HD Box later reprints it.
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '',
    );
  });

  testWidgets('an empty list explains why rather than looking broken', (
    tester,
  ) async {
    final viewModel = IntegrationsViewModel(_FakeRepo(empty: true));
    await viewModel.loadPrices(IntegrationProviderKey.hdbox);
    await tester.pumpWidget(harness(viewModel));
    await tester.pumpAndSettle();

    expect(find.textContaining('ابحث عن بطاقة مرة واحدة'), findsOneWidget);
  });
}

class _FakeRepo extends IntegrationsRepository {
  _FakeRepo({
    this.empty = false,
    this.belowCost = false,
    this.pricedFirst = false,
  }) : super(PosApiService());

  final bool empty;
  final bool belowCost;
  final bool pricedFirst;
  Map<String, double?> saved = const {};

  @override
  Future<Result<IntegrationPriceList>> loadPrices(String providerKey) async {
    if (empty) return const Ok(IntegrationPriceList());
    return Ok(
      IntegrationPriceList(
        options: [
          IntegrationOptionPrice(
            optionCode: 'renew:1',
            kind: 'renew',
            months: 1,
            lastCost: 25,
            price: pricedFirst ? 30 : null,
            suggestedPrice: 30,
            isSuggested: !pricedFirst,
            effectivePrice: 30,
            margin: 5,
          ),
          IntegrationOptionPrice(
            optionCode: 'renew:12',
            kind: 'renew',
            months: 12,
            lastCost: belowCost ? 250 : 220,
            price: belowCost ? 240 : null,
            suggestedPrice: 240,
            isSuggested: !belowCost,
            effectivePrice: 240,
            margin: belowCost ? -10 : 20,
            isBelowCost: belowCost,
          ),
        ],
      ),
    );
  }

  @override
  Future<Result<IntegrationPriceList>> savePrices(
    String providerKey,
    Map<String, double?> prices,
  ) async {
    saved = prices;
    return loadPrices(providerKey);
  }
}
