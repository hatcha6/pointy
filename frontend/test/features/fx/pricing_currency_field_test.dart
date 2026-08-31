import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/exchange_rate.dart';
import 'package:pointy_frontend/src/features/catalog/views/pricing_currency_field.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';

const _currencies = [
  Currency(
    code: 'USD',
    nameAr: 'دولار أمريكي',
    nameEn: 'US Dollar',
    symbolAr: r'$',
    symbolEn: r'$',
  ),
];

ResolvedRate _rate({double value = 6.85, bool stale = false}) => ResolvedRate(
  fromCode: 'USD',
  toCode: 'LYD',
  rate: value,
  effectiveAt: DateTime(2026, 8, 31),
  source: RateSource.relay,
  instrument: SettlementInstrument.cash,
  bankCode: '',
  requestedInstrument: SettlementInstrument.cash,
  requestedBankCode: '',
  isStale: stale,
);

Future<void> _pump(
  WidgetTester tester, {
  required String selected,
  ResolvedRate? rate,
  double? amount,
  List<Currency> currencies = _currencies,
  ValueChanged<String>? onChanged,
}) async {
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
        body: PricingCurrencyField(
          currencies: currencies,
          baseCurrencyCode: 'LYD',
          selectedCode: selected,
          onChanged: onChanged ?? (_) {},
          rate: rate,
          enteredAmount: amount,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    configureCurrencySymbol('د.ل', code: 'LYD');
    configureForeignCurrencySymbols(const {'USD': r'$'});
  });

  testWidgets('is hidden entirely when the shop has no other currencies', (
    tester,
  ) async {
    // A shop with no foreign exposure never meets the concept.
    await _pump(tester, selected: '', currencies: const []);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
  });

  testWidgets('offers the shop currency plus each enabled currency', (
    tester,
  ) async {
    await _pump(tester, selected: '');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.textContaining('(USD)'), findsWidgets);
  });

  testWidgets('shows no conversion preview while priced in base currency', (
    tester,
  ) async {
    await _pump(tester, selected: '', rate: _rate(), amount: 12);
    expect(find.textContaining('≈'), findsNothing);
  });

  testWidgets('previews the converted price as it is typed', (tester) async {
    await _pump(tester, selected: 'USD', rate: _rate(), amount: 12);
    // The number the owner sees is the number that gets stored.
    expect(find.textContaining('82.20'), findsOneWidget);
  });

  testWidgets('shows the rate itself when no price is typed yet', (
    tester,
  ) async {
    await _pump(tester, selected: 'USD', rate: _rate());
    expect(find.textContaining('6.85'), findsOneWidget);
  });

  testWidgets('says so plainly when no rate is known', (tester) async {
    // Better than a converted number we cannot stand behind.
    await _pump(tester, selected: 'USD', rate: null, amount: 12);
    expect(find.textContaining('USD'), findsWidgets);
    expect(find.textContaining('82.20'), findsNothing);
  });

  testWidgets('flags a stale rate rather than presenting it as current', (
    tester,
  ) async {
    await _pump(tester, selected: 'USD', rate: _rate(stale: true), amount: 12);
    expect(find.textContaining('82.20'), findsOneWidget);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.exchangeRateStaleBadge), findsOneWidget);
  });

  testWidgets('reports the picked currency to its parent', (tester) async {
    String? picked;
    await _pump(tester, selected: '', onChanged: (code) => picked = code);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('(USD)').last);
    await tester.pumpAndSettle();
    expect(picked, 'USD');
  });
}
