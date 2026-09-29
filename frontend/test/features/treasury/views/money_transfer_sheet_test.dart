import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/money_position.dart';
import 'package:pointy_frontend/src/data/repositories/treasury_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/treasury/view_models/money_position_view_model.dart';
import 'package:pointy_frontend/src/features/treasury/views/money_transfer_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// A provider float is the shop's money held by one provider. It can be topped
/// up from the cash box and refunded into it, but LNET's credit cannot pay HD
/// Box. The server refuses that, and the sheet says so before trying.
void main() {
  const betweenFloats = 'لا يمكن التحويل من رصيد مزوّد إلى رصيد مزوّد آخر.';

  Future<_FakeTreasuryRepository> openSheet(WidgetTester tester) async {
    final repository = _FakeTreasuryRepository();
    final viewModel = MoneyPositionViewModel(repository);
    addTearDown(viewModel.dispose);
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                // From the LNET float, as the float's own details sheet opens
                // it. The sheet then offers the other float as the target.
                onPressed: () => showMoneyTransferSheet(
                  context,
                  viewModel: viewModel,
                  fromAccountId: 3,
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
    await tester.enterText(find.widgetWithText(TextFormField, 'المبلغ'), '150');
    return repository;
  }

  testWidgets('one provider float cannot fund another', (tester) async {
    final repository = await openSheet(tester);

    await tester.tap(find.text('تسجيل التحويل'));
    await tester.pumpAndSettle();

    expect(find.text(betweenFloats), findsOneWidget);
    expect(repository.recorded, isEmpty);
  });

  testWidgets('a float can be refunded into the cash box', (tester) async {
    final repository = await openSheet(tester);

    await tester.tap(find.byType(DropdownButtonFormField<int?>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الخزينة · 500.00 د.ل').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('تسجيل التحويل'));
    await tester.pumpAndSettle();

    expect(find.text(betweenFloats), findsNothing);
    expect(repository.recorded.single.fromAccountId, 3);
    expect(repository.recorded.single.toAccountId, 1);
  });
}

class _FakeTreasuryRepository extends TreasuryRepository {
  _FakeTreasuryRepository() : super(PosApiService());

  final recorded = <MoneyTransferDraft>[];

  @override
  Future<Result<MoneyPosition>> loadPosition({DateTime? asOf}) async {
    return const Ok(
      MoneyPosition(
        accounts: [
          MoneyAccountPosition(
            account: MoneyAccount(
              id: 1,
              name: 'الخزينة',
              kind: MoneyAccountKind.cash,
              isDefault: true,
              isRouted: true,
            ),
            expectedBalance: 500,
          ),
          MoneyAccountPosition(
            account: MoneyAccount(
              id: 3,
              name: 'رصيد LNET',
              kind: MoneyAccountKind.provider,
            ),
            expectedBalance: 400,
          ),
          MoneyAccountPosition(
            account: MoneyAccount(
              id: 4,
              name: 'رصيد HDBOX',
              kind: MoneyAccountKind.provider,
            ),
            expectedBalance: 250,
          ),
        ],
        totals: MoneyPositionTotals(cash: 500, total: 500),
      ),
    );
  }

  @override
  Future<Result<void>> recordTransfer(
    MoneyTransferDraft draft, {
    String? idempotencyKey,
  }) async {
    recorded.add(draft);
    return const Ok(null);
  }
}
