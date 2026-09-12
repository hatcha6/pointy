import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/exchange_rate.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/fx_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/dashboard/view_models/dashboard_fx_view_model.dart';
import 'package:pointy_frontend/src/features/dashboard/views/dashboard_fx_band.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';

/// The exchange-rate band on the dashboard.
///
/// What is worth pinning here is not the pixels: it is that the band never
/// invents a rate, never draws a trend off the wrong settlement series, and
/// never costs a shop a request it cannot use.
class _FakeFxRepository extends FxRepository {
  _FakeFxRepository({this.rates = const [], this.history = const []})
    : super(PosApiService());

  final List<ResolvedRate> rates;
  final List<ExchangeRate> history;

  final List<String?> historyRequests = [];

  @override
  Future<Result<CurrentRates>> loadCurrentRates() async {
    return Ok(
      CurrentRates(
        baseCode: 'LYD',
        instrument: SettlementInstrument.cash,
        bankCode: '',
        stalenessHours: 24,
        rates: rates,
      ),
    );
  }

  @override
  Future<Result<List<ExchangeRate>>> loadRateHistory({
    String? fromCode,
    int pageSize = 100,
  }) async {
    historyRequests.add(fromCode);
    return Ok(
      history.where((row) => row.fromCode == fromCode).toList(growable: false),
    );
  }
}

ResolvedRate _rate(
  String code,
  double value, {
  double ageHours = 3,
  bool isStale = false,
  bool inverted = false,
  SettlementInstrument instrument = SettlementInstrument.cash,
  String bankCode = '',
}) {
  return ResolvedRate(
    fromCode: code,
    toCode: 'LYD',
    rate: value,
    effectiveAt: DateTime(2026, 9, 12),
    source: RateSource.relay,
    instrument: instrument,
    bankCode: bankCode,
    requestedInstrument: SettlementInstrument.cash,
    requestedBankCode: '',
    isStale: isStale,
    inverted: inverted,
    ageHours: ageHours,
  );
}

ExchangeRate _row(
  String code,
  double value,
  int hoursAgo, {
  SettlementInstrument instrument = SettlementInstrument.cash,
  String bankCode = '',
}) {
  return ExchangeRate(
    id: hoursAgo,
    fromCode: code,
    toCode: 'LYD',
    rate: value,
    instrument: instrument,
    bankCode: bankCode,
    source: RateSource.relay,
    effectiveAt: DateTime(2026, 9, 12).subtract(Duration(hours: hoursAgo)),
  );
}

Future<void> _pumpBand(
  WidgetTester tester,
  DashboardFxViewModel viewModel, {
  double width = 900,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      home: Scaffold(
        // The real dashboard body is a scroll view, so the band is laid out
        // with unbounded height. That is exactly what broke it once.
        body: SingleChildScrollView(
          child: SizedBox(
            width: width,
            child: DashboardFxBand(viewModel: viewModel),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    configureCurrencySymbol('د.ل', code: 'LYD');
  });

  test('tracks USD, EUR and GBP in that order and skips what is missing', () {
    final viewModel = DashboardFxViewModel(
      _FakeFxRepository(rates: [_rate('GBP', 8.63), _rate('USD', 6.85)]),
    );
    addTearDown(viewModel.dispose);

    return viewModel.load().then((_) {
      expect(viewModel.tracked.map((rate) => rate.fromCode), <String>[
        'USD',
        'GBP',
      ]);
    });
  });

  test(
    'stays hidden when the shop has no rate for any tracked currency',
    () async {
      final viewModel = DashboardFxViewModel(
        // TND is a real currency the backend serves; it is simply not one the
        // band shows, and one currency alone must not summon the band.
        _FakeFxRepository(rates: [_rate('TND', 2.21)]),
      );
      addTearDown(viewModel.dispose);

      await viewModel.load();

      expect(viewModel.isVisible, isFalse);
    },
  );

  test(
    'asks for history only for the currencies it is going to draw',
    () async {
      final repository = _FakeFxRepository(rates: [_rate('USD', 6.85)]);
      final viewModel = DashboardFxViewModel(repository);
      addTearDown(viewModel.dispose);

      await viewModel.load();
      await Future<void>.delayed(Duration.zero);

      expect(repository.historyRequests, <String>['USD']);
    },
  );

  test('builds the trend oldest-first from the resolved series only', () async {
    final repository = _FakeFxRepository(
      rates: [_rate('USD', 6.85)],
      history: [
        _row('USD', 6.85, 0),
        _row('USD', 6.80, 9),
        _row('USD', 6.74, 18),
        // A bank-settled quote for the same day: a different price for a
        // different way of paying, and never a point on the cash line.
        _row('USD', 7.10, 4, instrument: SettlementInstrument.bank),
      ],
    );
    final viewModel = DashboardFxViewModel(repository);
    addTearDown(viewModel.dispose);

    await viewModel.load();
    await Future<void>.delayed(Duration.zero);

    expect(viewModel.trendFor('USD'), <double>[6.74, 6.80, 6.85]);
  });

  test('draws no trend for an inverted rate', () async {
    final repository = _FakeFxRepository(
      rates: [_rate('USD', 6.85, inverted: true)],
      history: [_row('USD', 6.80, 9), _row('USD', 6.85, 0)],
    );
    final viewModel = DashboardFxViewModel(repository);
    addTearDown(viewModel.dispose);

    await viewModel.load();
    await Future<void>.delayed(Duration.zero);

    expect(viewModel.trendFor('USD'), isEmpty);
  });

  testWidgets('renders nothing at all before the rates land', (tester) async {
    final viewModel = DashboardFxViewModel(_FakeFxRepository());
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: PointyTheme.light(),
        home: Scaffold(body: DashboardFxBand(viewModel: viewModel)),
      ),
    );

    expect(find.byType(Card), findsNothing);
  });

  testWidgets('shows each rate with its age, inside a scroll view', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final viewModel = DashboardFxViewModel(
      _FakeFxRepository(rates: [_rate('USD', 6.85), _rate('EUR', 7.42)]),
    );
    addTearDown(viewModel.dispose);
    await viewModel.load();

    await _pumpBand(tester, viewModel);

    expect(tester.takeException(), isNull);
    expect(find.text(l10n.dashboardExchangeRatesTitle), findsOneWidget);
    expect(find.textContaining('6.85'), findsOneWidget);
    expect(find.textContaining('7.42'), findsOneWidget);
    expect(find.text(l10n.exchangeRateAgeHours(3)), findsNWidgets(2));
  });

  testWidgets('keeps the currency code whole on a phone-width band', (
    tester,
  ) async {
    final viewModel = DashboardFxViewModel(
      _FakeFxRepository(
        rates: [_rate('USD', 6.85), _rate('EUR', 7.42), _rate('GBP', 8.63)],
      ),
    );
    addTearDown(viewModel.dispose);
    await viewModel.load();

    // Three tiles across this leaves ~110px each, which is where the code used
    // to be the first thing ellipsised away.
    await _pumpBand(tester, viewModel, width: 358);

    expect(tester.takeException(), isNull);
    for (final code in const ['USD', 'EUR', 'GBP']) {
      final text = tester.widget<Text>(find.textContaining(code));
      expect(text.overflow, isNot(TextOverflow.ellipsis));
    }
  });

  testWidgets('flags a stale rate rather than presenting it as current', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final viewModel = DashboardFxViewModel(
      _FakeFxRepository(
        rates: [_rate('USD', 6.85, ageHours: 96, isStale: true)],
      ),
    );
    addTearDown(viewModel.dispose);
    await viewModel.load();

    await _pumpBand(tester, viewModel);

    expect(find.text(l10n.exchangeRateStaleBadge), findsOneWidget);
    expect(find.text(l10n.exchangeRateAgeDays(4)), findsOneWidget);
  });

  // The band costs a request per load, so the gate has to be the permission,
  // not the response — the same lesson the AI digest taught after being told
  // 403 seventy-nine times in the field.
  test('a cashier never gets the rates capability', () {
    final capabilities = AuthorizationCapabilities.forUser(_user('cashier'));

    expect(capabilities.canViewExchangeRates, isFalse);
  });

  test('an accountant reading rates gets it without a sales dashboard', () {
    final capabilities = AuthorizationCapabilities.forUser(
      _user('accountant', permissions: const ['fx.view_exchangerate']),
    );

    expect(capabilities.canViewExchangeRates, isTrue);
    expect(capabilities.canViewSalesDashboard, isFalse);
  });
}

PosUser _user(String role, {List<String> permissions = const []}) {
  return PosUser.fromJson({
    'id': 2,
    'username': role,
    'display_name': role,
    'email': '',
    'role': role,
    'permissions': permissions,
    'is_active': true,
  });
}
