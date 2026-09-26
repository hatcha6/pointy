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
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';
import '../../../shared/role_fixtures.dart';

/// الخزينة answers one question — how much should be in the box and the bank,
/// and does reality agree. These tests hold it to that: the total is stated,
/// the disagreement is impossible to miss, and the arithmetic behind a balance
/// is one tap away rather than a number the owner has to trust blindly.
void main() {
  testWidgets('the screen leads with the money and splits cash from bank', (
    tester,
  ) async {
    await _pumpPosition(tester, position: _position());

    expect(find.text('إجمالي أموال المحل'), findsOneWidget);
    expect(find.text('1250.00 د.ل'), findsOneWidget); // cash + bank
    expect(find.text('الصناديق النقدية'), findsOneWidget);
    expect(find.text('الحسابات المصرفية'), findsOneWidget);
    expect(find.text('الخزينة'), findsWidgets);
    expect(find.text('حساب التشغيل'), findsOneWidget);
    expect(find.text('مصرف الوحدة'), findsOneWidget);
  });

  testWidgets('an account that disagrees with its count is called out', (
    tester,
  ) async {
    await _pumpPosition(
      tester,
      position: _position(
        cashCount: _count(counted: 480, expected: 500),
        accountsWithVariance: 1,
      ),
    );

    expect(find.text('حساب واحد لا يطابق الجرد'), findsOneWidget);
    expect(find.text('عجز 20.00 د.ل'), findsOneWidget);
  });

  testWidgets('an uncounted account says the balance is derived, not proved', (
    tester,
  ) async {
    await _pumpPosition(tester, position: _position());

    expect(find.text('لم تجرد كل الحسابات بعد'), findsOneWidget);
    expect(find.text('لم يُجرد بعد'), findsWidgets);
  });

  testWidgets('opening an account shows the arithmetic behind its balance', (
    tester,
  ) async {
    await _pumpPosition(tester, position: _position());

    // Tap the cash card by its balance: 'الخزينة' also titles the app bar.
    await tester.tap(find.text('500.00 د.ل'));
    await tester.pumpAndSettle();

    expect(find.text('من أين جاء هذا الرصيد'), findsOneWidget);
    expect(find.text('الرصيد الافتتاحي'), findsOneWidget);
    expect(find.text('المبيعات والمقبوضات'), findsOneWidget);
    expect(find.text('المصروفات'), findsOneWidget);
    // The payroll routing is an assumption, so the sheet says so out loud.
    expect(find.textContaining('الرواتب محسوبة نقدًا'), findsOneWidget);
  });

  testWidgets('a shop with no accounts is told what to do, not shown zero', (
    tester,
  ) async {
    await _pumpPosition(
      tester,
      position: const MoneyPosition(
        accounts: [],
        totals: MoneyPositionTotals(),
      ),
    );

    expect(find.text('لا توجد حسابات بعد'), findsOneWidget);
    expect(find.text('0.00 د.ل'), findsNothing);
  });

  group('each write is offered only to someone the server will let do it', () {
    // The auditor role reads every account, transfer and count, and holds
    // none of the writes. Before, the screen offered it all of them.
    testWidgets('an auditor reads the money and is offered none of it', (
      tester,
    ) async {
      await _pumpPosition(
        tester,
        position: _position(),
        user: userWithRole(UserRole.auditor, auditorPermissions),
      );

      expect(find.text('1250.00 د.ل'), findsOneWidget);
      expect(find.byTooltip('حساب جديد'), findsNothing);
      for (final action in ['إضافة رصيد', 'إيداع في المصرف', 'سحب', 'جرد']) {
        expect(find.text(action), findsNothing, reason: action);
      }

      // The drill-down is reading, so it still opens — without its buttons.
      await tester.tap(find.text('500.00 د.ل'));
      await tester.pumpAndSettle();

      expect(find.text('من أين جاء هذا الرصيد'), findsOneWidget);
      expect(_sheetButton('count'), findsNothing);
      expect(_sheetButton('transfer'), findsNothing);
      expect(_sheetButton('edit'), findsNothing);
    });

    testWidgets('each button follows its own permission', (tester) async {
      await _pumpPosition(
        tester,
        position: _position(),
        user: userWithRole(UserRole.auditor, {
          ...auditorPermissions,
          'treasury.add_moneycount',
        }),
      );

      expect(find.text('جرد'), findsOneWidget);
      expect(find.text('إضافة رصيد'), findsNothing);
      expect(find.text('إيداع في المصرف'), findsNothing);
      expect(find.text('سحب'), findsNothing);

      await tester.tap(find.text('500.00 د.ل'));
      await tester.pumpAndSettle();

      expect(_sheetButton('count'), findsOneWidget);
      expect(_sheetButton('transfer'), findsNothing);
      expect(_sheetButton('edit'), findsNothing);
    });

    testWidgets('the accountant keeps every button', (tester) async {
      await _pumpPosition(
        tester,
        position: _position(),
        user: userWithRole(UserRole.accountant, accountantPermissions),
      );

      expect(find.byTooltip('حساب جديد'), findsOneWidget);
      for (final action in ['إضافة رصيد', 'إيداع في المصرف', 'سحب', 'جرد']) {
        expect(find.text(action), findsOneWidget, reason: action);
      }

      await tester.tap(find.text('500.00 د.ل'));
      await tester.pumpAndSettle();

      expect(_sheetButton('count'), findsOneWidget);
      expect(_sheetButton('transfer'), findsOneWidget);
      expect(_sheetButton('edit'), findsOneWidget);
    });

    testWidgets('an empty treasury does not ask an auditor to add to it', (
      tester,
    ) async {
      await _pumpPosition(
        tester,
        position: const MoneyPosition(
          accounts: [],
          totals: MoneyPositionTotals(),
        ),
        user: userWithRole(UserRole.auditor, auditorPermissions),
      );

      expect(find.text('لا توجد حسابات بعد'), findsOneWidget);
      expect(find.textContaining('«إضافة حسابات»'), findsOneWidget);
      expect(find.text('حساب جديد'), findsNothing);
      expect(find.byTooltip('حساب جديد'), findsNothing);
    });
  });
}

/// A button in the account sheet. By key, because the screen behind the sheet
/// carries buttons with the same words.
Finder _sheetButton(String action) =>
    find.byKey(ValueKey('treasury_details_${action}_button'));

Future<MoneyPositionViewModel> _pumpPosition(
  WidgetTester tester, {
  required MoneyPosition position,
  PosUser? user,
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final repository = _FakeTreasuryRepository()..position = position;
  final viewModel = MoneyPositionViewModel(repository);
  addTearDown(viewModel.dispose);

  final navigation = FakeAppNavigation(currentUser: user ?? _manager());
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
  return viewModel;
}

class _FakeTreasuryRepository extends TreasuryRepository {
  _FakeTreasuryRepository() : super(PosApiService());

  late MoneyPosition position;

  @override
  Future<Result<MoneyPosition>> loadPosition({DateTime? asOf}) async {
    return Ok(position);
  }

  @override
  Future<Result<MoneyMovementPage>> loadAccountMovements(
    int accountId, {
    DateTime? start,
    DateTime? end,
  }) async {
    return const Ok(MoneyMovementPage(rows: []));
  }
}

MoneyPosition _position({MoneyCount? cashCount, int accountsWithVariance = 0}) {
  return MoneyPosition(
    accounts: [
      MoneyAccountPosition(
        account: const MoneyAccount(
          id: 1,
          name: 'الخزينة',
          kind: MoneyAccountKind.cash,
          isDefault: true,
          isRouted: true,
        ),
        expectedBalance: 500,
        components: const [
          MoneyPositionComponent(code: 'opening', amount: 100, isInflow: true),
          MoneyPositionComponent(code: 'sales', amount: 460, isInflow: true),
          MoneyPositionComponent(
            code: 'expenses',
            amount: -60,
            isInflow: false,
          ),
        ],
        lastCount: cashCount,
      ),
      MoneyAccountPosition(
        account: const MoneyAccount(
          id: 2,
          name: 'حساب التشغيل',
          kind: MoneyAccountKind.bank,
          bankName: 'مصرف الوحدة',
          isDefault: true,
          isRouted: true,
        ),
        expectedBalance: 750,
        components: const [
          MoneyPositionComponent(code: 'opening', amount: 750, isInflow: true),
        ],
      ),
    ],
    totals: MoneyPositionTotals(
      cash: 500,
      bank: 750,
      total: 1250,
      accountsCounted: cashCount == null ? 0 : 1,
      accountsTotal: 2,
      accountsWithVariance: accountsWithVariance,
    ),
  );
}

MoneyCount _count({required double counted, required double expected}) {
  return MoneyCount(
    id: 1,
    accountId: 1,
    countedAmount: counted,
    expectedAmount: expected,
    variance: counted - expected,
    countedAt: DateTime(2026, 8, 27, 18, 30),
  );
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
