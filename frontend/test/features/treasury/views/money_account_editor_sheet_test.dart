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

/// The editor an owner reaches for to correct an imported cash box.
///
/// The field report: an imported "الخزينة الرئيسية" came across with an opening
/// balance the shop did not want; the owner typed zero, pressed save, and got
/// "could not save" and nothing else. The server was refusing every edit to a
/// second account of a kind (fixed in the serializer); these hold the sheet to
/// the other half — sending what it should, and saying why when it cannot.
void main() {
  const imported = MoneyAccount(
    id: 7,
    name: 'الخزينة الرئيسية',
    kind: MoneyAccountKind.cash,
    openingBalance: 71751.5,
    displayOrder: 3,
    notes: 'من النظام السابق',
  );

  testWidgets('zero is a real opening balance and is sent as one', (
    tester,
  ) async {
    final repository = _FakeTreasuryRepository();
    await _openEditor(tester, repository, imported);

    await tester.enterText(
      find.byKey(const ValueKey('money_account_opening_balance_field')),
      '0',
    );
    await tester.tap(find.byKey(const ValueKey('money_account_save_button')));
    await tester.pumpAndSettle();

    final sent = repository.updates.single;
    expect(sent['opening_balance'], '0.00');
    // Not on the form, but on the account: a save must not wipe them.
    expect(sent['notes'], 'من النظام السابق');
    expect(sent['display_order'], 3);
  });

  testWidgets('a refusal says why, in the server\'s own words', (tester) async {
    final repository = _FakeTreasuryRepository()
      ..refuseWith = const PosApiException(
        message: 'Money account update failed with status 400',
        statusCode: 400,
        responseBody: '{"opening_at": ["الفترة مقفلة."]}',
      );
    await _openEditor(tester, repository, imported);

    await tester.tap(find.byKey(const ValueKey('money_account_save_button')));
    await tester.pumpAndSettle();

    expect(find.text('الفترة مقفلة.'), findsOneWidget);
  });

  testWidgets('something that is not a number is refused, not saved as 0', (
    tester,
  ) async {
    final repository = _FakeTreasuryRepository();
    await _openEditor(tester, repository, imported);

    await tester.enterText(
      find.byKey(const ValueKey('money_account_opening_balance_field')),
      '1..5',
    );
    await tester.tap(find.byKey(const ValueKey('money_account_save_button')));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(
      find.text(l10n.treasuryAccountOpeningBalanceInvalid),
      findsOneWidget,
    );
    expect(repository.updates, isEmpty);
  });
}

Future<void> _openEditor(
  WidgetTester tester,
  _FakeTreasuryRepository repository,
  MoneyAccount account,
) async {
  final viewModel = MoneyPositionViewModel(repository);
  addTearDown(viewModel.dispose);
  await tester.binding.setSurfaceSize(const Size(900, 1400));
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

class _FakeTreasuryRepository extends TreasuryRepository {
  _FakeTreasuryRepository() : super(PosApiService());

  final List<Map<String, Object?>> updates = [];
  PosApiException? refuseWith;

  @override
  Future<Result<MoneyAccount>> updateAccount(
    int accountId,
    Map<String, Object?> changes,
  ) async {
    final refusal = refuseWith;
    if (refusal != null) return Error(refusal);
    updates.add(changes);
    return Ok(MoneyAccount.fromJson({...changes, 'id': accountId}));
  }

  @override
  Future<Result<MoneyPosition>> loadPosition({DateTime? asOf}) async =>
      Error(Exception('not needed here'));
}
