import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/register_session_summary.dart';
import 'package:pointy_frontend/src/data/services/z_report_cash.dart';
import 'package:pointy_frontend/src/features/register_sessions/pdf/z_report_pdf.dart';
import 'package:pointy_frontend/src/features/pos/views/register_session_close_sheet.dart';

PosUser _cashierWith(List<String> effective) => PosUser.fromJson({
  'id': 2,
  'username': 'till',
  'assigned_role': 'cashier',
  'is_active': true,
  'effective_permissions': effective,
});

Future<void> _pumpSheet(
  WidgetTester tester, {
  Future<double?> Function()? loadExpectedCash,
}) {
  return tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: RegisterSessionCloseSheet(
          onClose: (_) async => true,
          loadExpectedCash: loadExpectedCash,
        ),
      ),
    ),
  );
}

/// The summary's cash block as the server sends it to a cashier closing
/// blind: what they handled, none of what the drawer should hold.
const _blindCash = <String, Object?>{
  'opening_cash': '40.00',
  'closing_cash': '35.00',
  'denominations': [
    {'value': '0.25', 'count': 0},
  ],
};

const _grantedCash = <String, Object?>{
  ..._blindCash,
  'cash_sales_total': '0.00',
  'pay_in_total': '0.00',
  'pay_out_total': '0.00',
  'cash_refund_total': '0.00',
  'expected_cash': '40.00',
  'cash_variance': '-5.00',
  'has_cash_variance': true,
  'denomination_total': '0.00',
};

List<String> _labels(List<Map<String, Object?>> rows) => [
  for (final row in rows) row['label']! as String,
];

const _comparison = ValueKey('register_session_expected_cash_comparison');

void main() {
  group('own register reconciliation grant', () {
    test('a plain cashier closes blind', () {
      final caps = AuthorizationCapabilities.forUser(
        _cashierWith(const ['sales.view_registersession']),
      );

      expect(caps.canViewRegisterReconciliation, isFalse);
    });

    test('the grant reveals the reconciliation', () {
      final caps = AuthorizationCapabilities.forUser(
        _cashierWith(const [
          'sales.view_registersession',
          'sales.view_own_register_reconciliation',
        ]),
      );

      expect(caps.canViewRegisterReconciliation, isTrue);
    });
  });

  group('RegisterSessionCloseSheet expected cash', () {
    testWidgets('stays blind without a loader', (tester) async {
      await _pumpSheet(tester);
      await tester.pump();

      expect(find.byKey(_comparison), findsNothing);
      expect(find.text('النقد المتوقع'), findsNothing);
    });

    testWidgets('names a shortage live while counting', (tester) async {
      await _pumpSheet(tester, loadExpectedCash: () async => 50);
      await tester.pump();

      await tester.enterText(
        find.byKey(const ValueKey('register_session_closing_cash_field')),
        '45',
      );
      await tester.pump();

      final comparison = find.byKey(_comparison);
      expect(comparison, findsOneWidget);
      expect(
        find.descendant(of: comparison, matching: find.text('50.00 د.ل')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: comparison, matching: find.text('5.00 د.ل')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('register_session_closing_cash_field')),
        '50',
      );
      await tester.pump();

      expect(
        find.descendant(of: comparison, matching: find.text('مطابق')),
        findsOneWidget,
      );
    });

    testWidgets('a failed read keeps the sheet usable', (tester) async {
      await _pumpSheet(tester, loadExpectedCash: () async => null);
      await tester.pump();

      expect(find.byKey(_comparison), findsNothing);
      expect(
        find.byKey(const ValueKey('register_session_close_submit_button')),
        findsOneWidget,
      );
    });
  });

  group('Z-Report cash section', () {
    test('a blind slip prints the count, not the expectation', () {
      final cash = SessionCashSummary.fromJson(_blindCash);

      expect(cash.hasReconciliation, isFalse);
      expect(_labels(zReportCashRows(cash)), [
        'النقد الافتتاحي',
        'النقد الفعلي',
      ]);
    });

    test('a granted slip prints the expectation and the shortage', () {
      final rows = zReportCashRows(SessionCashSummary.fromJson(_grantedCash));

      expect(_labels(rows), [
        'النقد الافتتاحي',
        'مبيعات نقدية',
        'النقد المتوقع',
        'النقد الفعلي',
        'العجز',
      ]);
    });

    test('a blind A4 copy still builds', () async {
      final bytes = await const RegisterZReportPdfService().buildBytes(
        summary: RegisterSessionSummary.fromJson({
          'session': {'id': 7, 'session_number': 'RS-7', 'status': 'closed'},
          'cash': _blindCash,
        }),
      );

      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });
}
