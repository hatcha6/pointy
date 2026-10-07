// Renders the expenses ledger to PNG, headlessly, so its lines — who recorded
// each one and when, and the links to the drawer session, purchase order or
// payroll run it came from — can be looked at instead of described.
//
// Not a golden gate: an ordinary `flutter test` run skips every case here.
// Capture with:
//
//   POINTY_CAPTURE_SCREENS=1 flutter test test/screens/expenses_capture_test.dart --update-goldens
//
// The PNGs land in test/screens/goldens/.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/expense_category.dart';
import 'package:pointy_frontend/src/data/models/expense_ledger_entry.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/expense_repository.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/expenses/view_models/expense_categories_view_model.dart';
import 'package:pointy_frontend/src/features/expenses/view_models/expenses_view_model.dart';
import 'package:pointy_frontend/src/features/expenses/views/expenses_screen.dart';
import 'package:pointy_frontend/src/features/settings/view_models/integrations_view_model.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import '../shared/fake_app_navigation.dart';

final bool _capture = Platform.environment['POINTY_CAPTURE_SCREENS'] == '1';

ThemeData _withButtonFont(ThemeData theme) {
  ButtonStyle patch(ButtonStyle? style) {
    return (style ?? const ButtonStyle()).copyWith(
      textStyle: WidgetStateProperty.resolveWith((states) {
        final resolved = style?.textStyle?.resolve(states);
        return (resolved ?? const TextStyle()).copyWith(
          fontFamily: PointyTypography.fontFamily,
        );
      }),
    );
  }

  return theme.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: patch(theme.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: patch(theme.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: patch(theme.textButtonTheme.style),
    ),
  );
}

String _flutterRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return Directory(
    Platform.resolvedExecutable,
  ).parent.parent.parent.parent.parent.path;
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
    for (final family in const ['IBMPlexSansArabic', 'Roboto']) {
      final loader = FontLoader(family);
      for (final weight in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        loader.addFont(
          rootBundle.load('assets/fonts/IBMPlexSansArabic-$weight.ttf'),
        );
      }
      await loader.load();
    }
    final iconFont = File(
      '${_flutterRoot()}/bin/cache/artifacts/material_fonts/'
      'MaterialIcons-Regular.otf',
    );
    if (iconFont.existsSync()) {
      final bytes = await iconFont.readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
    }
  });

  Future<void> shoot(
    WidgetTester tester, {
    required String name,
    required Size size,
    bool dark = false,
  }) async {
    debugDisableShadows = false;
    const ratio = 2.0;
    tester.view.devicePixelRatio = ratio;
    tester.view.physicalSize = size * ratio;
    addTearDown(tester.view.reset);

    final repository = _Repository();
    final navigation = FakeAppNavigation(currentUser: _manager());
    Future<bool> open(int _) async => true;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: _withButtonFont(dark ? PointyTheme.dark() : PointyTheme.light()),
        builder: (context, inner) => PointyNavigationRailScope(
          isActive: false,
          controller: PointyNavigationRailController(),
          child: inner ?? const SizedBox.shrink(),
        ),
        home: ExpensesScreen(
          viewModel: ExpensesViewModel(repository),
          categoriesViewModel: ExpenseCategoriesViewModel(repository),
          capabilities: navigation.capabilities,
          navigation: navigation,
          integrationsViewModel: IntegrationsViewModel(
            IntegrationsRepository(PosApiService()),
          ),
          onOpenRegisterSession: open,
          onOpenPurchaseOrder: open,
          onOpenPayrollRun: open,
          onOpenRecorder: (_, _) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    try {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/expenses_$name.png'),
      );
    } finally {
      debugDisableShadows = true;
    }
  }

  testWidgets('ledger, wide', (tester) async {
    await shoot(tester, name: 'ledger_wide', size: const Size(1100, 900));
  }, skip: !_capture);

  testWidgets('ledger, phone', (tester) async {
    await shoot(tester, name: 'ledger_phone', size: const Size(390, 1200));
  }, skip: !_capture);

  testWidgets('ledger, wide, dark', (tester) async {
    await shoot(
      tester,
      name: 'ledger_wide_dark',
      size: const Size(1100, 900),
      dark: true,
    );
  }, skip: !_capture);
}

PosUser _manager() {
  return PosUser.fromJson(const {
    'id': 4,
    'username': 'manager',
    'display_name': 'المدير',
    'email': '',
    'role': 'manager',
    'permissions': [
      'expenses.view_expense',
      'expenses.add_expense',
      'expenses.change_expense',
    ],
    'is_active': true,
  });
}

class _Repository extends ExpenseRepository {
  _Repository() : super(PosApiService());

  @override
  Future<Result<ExpenseLedger>> loadLedger({
    required DateTime start,
    required DateTime end,
  }) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final entries = [
      ExpenseLedgerEntry(
        source: ExpenseLedgerSource.registerPayout,
        date: today,
        amount: 15,
        description: 'أكياس تغليف',
        category: null,
        paymentMethod: 'cash',
        reference: '',
        relatedId: 31,
        recordedById: 9,
        recordedByName: 'سالم الورفلي',
        recordedAt: today.add(const Duration(hours: 14, minutes: 32)),
        registerSessionId: 12,
        registerSessionNumber: 'RS-12',
      ),
      ExpenseLedgerEntry(
        source: ExpenseLedgerSource.expense,
        date: today,
        amount: 120,
        description: 'فاتورة الكهرباء',
        category: 'مرافق',
        paymentMethod: 'cash',
        reference: '',
        relatedId: 44,
        recordedById: 4,
        recordedByName: 'المدير',
        recordedAt: today.add(const Duration(hours: 11, minutes: 5)),
        registerSessionId: 11,
        registerSessionNumber: 'RS-11',
      ),
      ExpenseLedgerEntry(
        source: ExpenseLedgerSource.purchase,
        date: today,
        amount: 640,
        description: 'شركة الأمل للتوزيع · PO-0042',
        category: null,
        paymentMethod: '',
        reference: 'INV-889',
        relatedId: 42,
        recordedById: 9,
        recordedByName: 'سالم الورفلي',
        recordedAt: today.add(const Duration(hours: 10, minutes: 20)),
        registerSessionId: 12,
        registerSessionNumber: 'RS-12',
        documentNumber: 'PO-0042',
      ),
      ExpenseLedgerEntry(
        source: ExpenseLedgerSource.payroll,
        date: today,
        amount: 4200,
        description: 'رواتب الشهر الماضي',
        category: null,
        paymentMethod: '',
        reference: '',
        relatedId: 3,
        recordedById: 4,
        recordedByName: 'المدير',
        recordedAt: today.add(const Duration(hours: 9)),
        documentNumber: 'PR-2026-09',
      ),
      ExpenseLedgerEntry(
        source: ExpenseLedgerSource.commission,
        date: today,
        amount: 18.4,
        description: 'عمولات الدفع',
        category: null,
        paymentMethod: '',
        reference: '',
        relatedId: null,
      ),
    ];
    return Ok(
      ExpenseLedger(
        start: start,
        end: end,
        entries: entries,
        totalsBySource: const {},
        total: entries.fold(0, (sum, entry) => sum + entry.amount),
        truncated: false,
        totalCount: entries.length,
      ),
    );
  }

  @override
  Future<Result<List<ExpenseCategory>>> loadCategories() async {
    return Ok(const [
      ExpenseCategory(id: 1, name: 'مرافق', isActive: true, displayOrder: 0),
    ]);
  }
}
