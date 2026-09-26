import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/money_position.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/treasury_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/treasury/view_models/money_position_view_model.dart';
import 'package:pointy_frontend/src/features/treasury/views/money_position_screen.dart';
import 'package:pointy_frontend/src/features/treasury/views/treasury_ui.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';

/// Every line of a balance's arithmetic, and every row under it, names its
/// money in Arabic. A code the labels did not know fell through to itself, so
/// a provider float printed `integration_draw` in its breakdown — every day,
/// once its balance subtracted every earlier draw — and a cash box that paid a
/// consignor printed `consignor_payout`.
void main() {
  testWidgets('a float names what its provider drew, in the line and rows', (
    tester,
  ) async {
    await _pumpPosition(tester);

    await tester.tap(find.text(_floatName));
    await tester.pumpAndSettle();

    // The breakdown line, and the two draws listed under it.
    expect(find.text('سحب مزوّد الخدمة'), findsNWidgets(3));
    expect(find.byIcon(Icons.cell_tower_outlined), findsNWidgets(2));
    expect(find.textContaining('تجديد 12 شهر'), findsOneWidget);
    expect(find.text('integration_draw'), findsNothing);
  });

  testWidgets('a cash box names what it paid the owners of consigned goods', (
    tester,
  ) async {
    await _pumpPosition(tester);

    await tester.tap(find.text(_cashName));
    await tester.pumpAndSettle();

    expect(find.text('مدفوعات أصحاب الأمانات'), findsOneWidget);
    expect(find.text('consignor_payout'), findsNothing);
  });

  test('every component code the backend sends has a label and an icon', () {
    final l10n = lookupAppLocalizations(const Locale('ar'));
    // backend/apps/treasury/position.py, COMPONENT_*: add, don't rename.
    const codes = [
      'opening',
      'sales',
      'drawer_in',
      'drawer_out',
      'expenses',
      'suppliers',
      'payroll',
      'commission',
      'transfer_in',
      'transfer_out',
      'consignor_payout',
      'integration_draw',
    ];

    for (final code in codes) {
      expect(treasuryComponentLabel(l10n, code), isNot(code), reason: code);
      expect(
        treasuryComponentIcon(code),
        isNot(Icons.circle_outlined),
        reason: code,
      );
    }
  });
}

const _cashName = 'الصندوق الرئيسي';
const _floatName = 'رصيد HDBOX — النسيم';

Future<void> _pumpPosition(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1100, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final viewModel = MoneyPositionViewModel(_FakeTreasuryRepository());
  addTearDown(viewModel.dispose);

  final navigation = FakeAppNavigation(currentUser: _manager());
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: MoneyPositionScreen(
          viewModel: viewModel,
          capabilities: navigation.capabilities,
          navigation: navigation,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeTreasuryRepository extends TreasuryRepository {
  _FakeTreasuryRepository() : super(PosApiService());

  @override
  Future<Result<MoneyPosition>> loadPosition({DateTime? asOf}) async {
    return const Ok(
      MoneyPosition(
        accounts: [
          MoneyAccountPosition(
            account: MoneyAccount(
              id: 1,
              name: _cashName,
              kind: MoneyAccountKind.cash,
              isDefault: true,
              isRouted: true,
            ),
            expectedBalance: 450,
            components: [
              MoneyPositionComponent(
                code: 'opening',
                amount: 100,
                isInflow: true,
              ),
              MoneyPositionComponent(
                code: 'sales',
                amount: 460,
                isInflow: true,
              ),
              MoneyPositionComponent(
                code: 'consignor_payout',
                amount: -110,
                isInflow: false,
              ),
            ],
          ),
          MoneyAccountPosition(
            account: MoneyAccount(
              id: 3,
              name: _floatName,
              kind: MoneyAccountKind.provider,
            ),
            expectedBalance: 700,
            components: [
              MoneyPositionComponent(
                code: 'integration_draw',
                amount: -300,
                isInflow: false,
              ),
              MoneyPositionComponent(
                code: 'transfer_in',
                amount: 1000,
                isInflow: true,
              ),
            ],
          ),
        ],
        totals: MoneyPositionTotals(cash: 450, total: 450, accountsTotal: 2),
      ),
    );
  }

  @override
  Future<Result<MoneyMovementPage>> loadAccountMovements(
    int accountId, {
    DateTime? start,
    DateTime? end,
  }) async {
    if (accountId != 3) {
      return const Ok(MoneyMovementPage(rows: []));
    }
    return Ok(
      MoneyMovementPage(
        rows: [
          MoneyMovement(
            source: 'integration_draw',
            amount: -80,
            isInflow: false,
            date: DateTime(2026, 9, 25),
            description: '0912345678 · تجديد 12 شهر',
            relatedId: 12,
          ),
          MoneyMovement(
            source: 'integration_draw',
            amount: -220,
            isInflow: false,
            date: DateTime(2026, 9, 23),
            description: '0923456789 · تجديد 3 أشهر',
            relatedId: 11,
          ),
          MoneyMovement(
            source: 'transfer_in',
            amount: 1000,
            isInflow: true,
            date: DateTime(2026, 9, 19),
            description: 'شحن رصيد وكالة',
            relatedId: 5,
          ),
        ],
      ),
    );
  }
}

/// Reading the treasury is a manager/accountant capability.
PosUser _manager() {
  return PosUser.fromJson(const {
    'id': 4,
    'username': 'manager',
    'display_name': 'المدير',
    'email': '',
    'role': 'manager',
    'permissions': ['payments.view_payment', 'treasury.view_moneyaccount'],
    'is_active': true,
  });
}
