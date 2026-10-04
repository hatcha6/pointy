import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/money_position.dart';
import 'package:pointy_frontend/src/data/repositories/treasury_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/treasury/view_models/money_position_view_model.dart';
import 'package:pointy_frontend/src/features/treasury/views/money_account_editor_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// Opening the account that holds Moamalat's card takings: it settles into
/// the shop's bank, has no opening balance of its own, and carries the
/// processor's schedule — and stopping it is asked once, in words.
void main() {
  testWidgets('a new clearing account settles into the shop bank', (
    tester,
  ) async {
    final repository = _FakeRepository();
    await _openEditor(tester, repository);

    await tester.tap(find.text('قيد التسوية'));
    await tester.pumpAndSettle();

    // The name an owner would have typed, and the bank card money falls to.
    expect(find.text('معاملات'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('money_account_opening_balance_field')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('money_account_default_switch')),
      findsNothing,
    );

    await _tapKey(tester, 'money_account_save_button');
    await tester.pumpAndSettle();

    final sent = repository.created.single.toJson();
    expect(sent['kind'], 'clearing');
    expect(sent['settles_into'], 2);
    expect(sent['opening_balance'], '0.00');
    expect(sent['is_default'], false);
    expect(sent['settlement_weekdays'], '0,1,2,3,6');
    expect(sent['settlement_lag_days'], 1);
    expect(sent['settlement_cutoff'], '00:00:00');
  });

  testWidgets('stopping a clearing account is confirmed before it is sent', (
    tester,
  ) async {
    final repository = _FakeRepository();
    await _openEditor(tester, repository, account: _clearing);

    await _tapKey(tester, 'money_account_active_switch');
    await tester.pumpAndSettle();
    expect(find.text('إيقاف احتجاز مبيعات البطاقات؟'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('money_account_clearing_stop_confirm')),
    );
    await tester.pumpAndSettle();
    await _tapKey(tester, 'money_account_save_button');
    await tester.pumpAndSettle();

    final sent = repository.updates.single;
    expect(sent['is_active'], false);
    expect(sent['settles_into'], 2);
  });
}

/// Taps a control by key, scrolling the sheet to it first: the form is
/// taller than the sheet on a phone-sized surface.
Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

const _bank = MoneyAccount(
  id: 2,
  name: 'حساب المحل',
  kind: MoneyAccountKind.bank,
  isDefault: true,
  isRouted: true,
);

const _clearing = MoneyAccount(
  id: 9,
  name: 'معاملات',
  kind: MoneyAccountKind.clearing,
  settlesIntoId: 2,
  settlesIntoName: 'حساب المحل',
);

Future<void> _openEditor(
  WidgetTester tester,
  _FakeRepository repository, {
  MoneyAccount? account,
}) async {
  final viewModel = MoneyPositionViewModel(repository);
  addTearDown(viewModel.dispose);
  await viewModel.load();
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMoneyAccountEditorSheet(
              context,
              viewModel: viewModel,
              account: account,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

class _FakeRepository extends TreasuryRepository {
  _FakeRepository() : super(PosApiService());

  final List<MoneyAccount> created = [];
  final List<Map<String, Object?>> updates = [];

  @override
  Future<Result<MoneyPosition>> loadPosition({DateTime? asOf}) async {
    return const Ok(
      MoneyPosition(
        accounts: [
          MoneyAccountPosition(account: _bank, expectedBalance: 500),
          MoneyAccountPosition(account: _clearing, expectedBalance: 99),
        ],
        totals: MoneyPositionTotals(bank: 500, inTransit: 99, total: 599),
      ),
    );
  }

  @override
  Future<Result<MoneyAccount>> createAccount(MoneyAccount account) async {
    created.add(account);
    return Ok(account);
  }

  @override
  Future<Result<MoneyAccount>> updateAccount(
    int accountId,
    Map<String, Object?> changes,
  ) async {
    updates.add(changes);
    return const Ok(_clearing);
  }
}
