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
import 'package:pointy_frontend/src/features/settings/views/integration_float_sheet.dart';

/// Recording a top-up moves the shop's own money from a cash box or bank into
/// the provider's float. The sheet never said where the money came from, so
/// every top-up was written as money arriving from outside the shop. The cash
/// box kept what it had paid the provider.
void main() {
  Future<void> openSheet(
    WidgetTester tester,
    IntegrationsViewModel viewModel,
  ) async {
    await viewModel.loadFloat(IntegrationProviderKey.hdbox);
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
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<bool>(
                    builder: (_) => Scaffold(
                      body: IntegrationFloatForm(
                        viewModel: viewModel,
                        providerKey: IntegrationProviderKey.hdbox,
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> pickSource(WidgetTester tester, String label) async {
    final field = find.byType(DropdownButtonFormField<int?>);
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester, String amount) async {
    await tester.enterText(
      find.widgetWithText(TextFormField, 'المبلغ المدفوع'),
      amount,
    );
    await tester.tap(find.text('تسجيل'));
    await tester.pumpAndSettle();
  }

  testWidgets('a top-up starts on the cash box and says so when saved', (
    tester,
  ) async {
    final repo = _FloatRepo();
    await openSheet(tester, IntegrationsViewModel(repo));

    expect(find.text('خرج من'), findsOneWidget);
    expect(find.text('الخزينة'), findsWidgets);
    // Nothing was taken back out of this float, so no row says so.
    expect(find.text('مُسترَد من المزوّد'), findsNothing);
    await save(tester, '1000');

    expect(repo.recorded, hasLength(1));
    expect(repo.recorded.single.amount, 1000);
    expect(repo.recorded.single.fromAccountId, 1);
    expect(repo.recorded.single.fromOutside, isFalse);
    // Saved and closed.
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a top-up paid by bank comes out of that bank', (tester) async {
    final repo = _FloatRepo();
    await openSheet(tester, IntegrationsViewModel(repo));

    await pickSource(tester, 'مصرف الجمهورية');
    await save(tester, '300');

    expect(repo.recorded.single.fromAccountId, 2);
    expect(repo.recorded.single.fromOutside, isFalse);
  });

  testWidgets('money from outside the shop is said in so many words', (
    tester,
  ) async {
    final repo = _FloatRepo();
    await openSheet(tester, IntegrationsViewModel(repo));

    const hint = 'لن يُخصم المبلغ من الخزينة، ويُحسب مالاً دخل المحل من خارجه.';
    expect(find.text(hint), findsNothing);
    await pickSource(tester, 'خارج المحل');
    expect(find.text(hint), findsOneWidget);
    await save(tester, '200');

    expect(repo.recorded.single.fromAccountId, isNull);
    expect(repo.recorded.single.fromOutside, isTrue);
  });

  testWidgets('an older server offers no choice, and the server decides', (
    tester,
  ) async {
    final repo = _FloatRepo(json: _floatJson(withSources: false));
    await openSheet(tester, IntegrationsViewModel(repo));

    expect(find.text('خرج من'), findsNothing);
    await save(tester, '50');

    // Not outside: said nothing, so the server takes its cash box.
    expect(repo.recorded.single.fromAccountId, isNull);
    expect(repo.recorded.single.fromOutside, isFalse);
  });

  testWidgets('a float that did not load still records from the cash box', (
    tester,
  ) async {
    final repo = _FloatRepo(failLoad: true);
    await openSheet(tester, IntegrationsViewModel(repo));

    expect(find.text('خرج من'), findsNothing);
    await save(tester, '75');

    expect(repo.recorded.single.fromAccountId, isNull);
    expect(repo.recorded.single.fromOutside, isFalse);
  });

  testWidgets('money taken back out of the float is listed beside it', (
    tester,
  ) async {
    final refunded = {..._floatJson(), 'returned': '300.00'};
    await openSheet(tester, IntegrationsViewModel(_FloatRepo(json: refunded)));

    expect(find.text('مُسترَد من المزوّد'), findsOneWidget);
    expect(find.text('300.00 د.ل'), findsOneWidget);
    expect(IntegrationFloat.fromJson(refunded).returned, 300);
    // A server that predates the figure reads as nothing taken back.
    expect(IntegrationFloat.fromJson(_floatJson()).returned, 0);
  });

  test('the float carries where a top-up can come from', () {
    final float = IntegrationFloat.fromJson(_floatJson());

    expect(float.sourceAccounts.map((account) => account.name), [
      'الخزينة',
      'مصرف الجمهورية',
    ]);
    expect(float.sourceAccounts.first.isCash, isTrue);
    expect(float.defaultSourceAccountId, 1);
    expect(
      IntegrationFloat.fromJson(_floatJson(withSources: false)).sourceAccounts,
      isEmpty,
    );
  });
}

Map<String, Object?> _floatJson({bool withSources = true}) => {
  'expected_balance': '780.00',
  'topped_up': '1000.00',
  'drawn': '220.00',
  'committed': '65.00',
  'reported_balance': '780.00',
  'reported_at': null,
  'drift': '0.00',
  'money_account_id': 9,
  'money_account_name': 'رصيد HDBOX — Alnassim',
  if (withSources) ...{
    'source_accounts': [
      {'id': 1, 'name': 'الخزينة', 'kind': 'cash'},
      {'id': 2, 'name': 'مصرف الجمهورية', 'kind': 'bank'},
    ],
    'default_source_account_id': 1,
  },
};

typedef _TopUp = ({double amount, int? fromAccountId, bool fromOutside});

class _FloatRepo extends IntegrationsRepository {
  _FloatRepo({Map<String, Object?>? json, this.failLoad = false})
    : _json = json ?? _floatJson(),
      super(PosApiService());

  final Map<String, Object?> _json;
  final bool failLoad;
  final recorded = <_TopUp>[];

  @override
  Future<Result<IntegrationFloat>> loadFloat(String providerKey) async {
    if (failLoad) return Error(Exception('offline'));
    return Ok(IntegrationFloat.fromJson(_json));
  }

  @override
  Future<Result<IntegrationFloat>> recordTopUp(
    String providerKey, {
    required double amount,
    int? fromAccountId,
    bool fromOutside = false,
    String reference = '',
    String note = '',
  }) async {
    recorded.add((
      amount: amount,
      fromAccountId: fromAccountId,
      fromOutside: fromOutside,
    ));
    return Ok(IntegrationFloat.fromJson(_json));
  }
}
