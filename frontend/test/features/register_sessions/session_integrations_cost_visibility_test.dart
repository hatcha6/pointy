import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/register_session_summary.dart';
import 'package:pointy_frontend/src/features/register_sessions/pdf/z_report_pdf.dart';
import 'package:pointy_frontend/src/features/register_sessions/views/session_integrations_section.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// A cashier reviewing their own shift sees what the provider sales took, not
/// what they cost the shop or made it. The server leaves the provider's share
/// and the margin out for anyone outside the reporting roles; these pin that
/// the shift screen and the A4 copy read "not sent" as "not shown" — never as
/// a cost of nothing and a profit of nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the summary as a cashier is sent it', () {
    test('has no cost or margin anywhere, and keeps the rest', () {
      final integrations = SessionIntegrations.fromJson(_payload(costs: false));

      expect(integrations.showsCost, isFalse);
      final hdbox = integrations.providers.single;
      expect(hdbox.cost, isNull);
      expect(hdbox.margin, isNull);
      expect(hdbox.sold, 30);
      expect(hdbox.delivered.cost, isNull);
      expect(hdbox.delivered.amount, 30);
      expect(hdbox.refundedAfterDelivery.count, 1);
      expect(hdbox.refundedAfterDelivery.cost, isNull);
      expect(integrations.transactions.first.cost, isNull);
      expect(integrations.transactions.first.price, 30);
    });

    testWidgets('shows what customers paid and nothing the shop paid', (
      tester,
    ) async {
      await _pump(tester, SessionIntegrations.fromJson(_payload(costs: false)));
      await tester.tap(find.text('العمليات (1)'));
      await tester.pumpAndSettle();

      expect(find.text('دفعه الزبائن'), findsOneWidget);
      expect(find.text('حصة المزوّد من رصيد الوكالة'), findsNothing);
      expect(find.text('ربح المتجر'), findsNothing);
      expect(
        find.byKey(const ValueKey('session_integration_transaction_1')),
        findsOneWidget,
      );
      expect(find.textContaining('التكلفة'), findsNothing);
      // That the float paid for a refunded sale is still said.
      expect(
        find.textContaining('فخُصمت من رصيد الوكالة دون مقابل'),
        findsOneWidget,
      );
    });

    test('still prints an A4 copy', () async {
      final bytes = await const RegisterZReportPdfService().buildBytes(
        summary: RegisterSessionSummary.fromJson({
          'session': {'id': 7, 'session_number': 'RS-7', 'status': 'closed'},
          'integrations': _payload(costs: false),
        }),
      );

      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });

  testWidgets('the reporting roles still see the split', (tester) async {
    final integrations = SessionIntegrations.fromJson(_payload(costs: true));
    expect(integrations.showsCost, isTrue);

    await _pump(tester, integrations);
    await tester.tap(find.text('العمليات (1)'));
    await tester.pumpAndSettle();

    expect(find.text('حصة المزوّد من رصيد الوكالة'), findsOneWidget);
    expect(find.text('ربح المتجر'), findsOneWidget);
    expect(find.textContaining('التكلفة'), findsOneWidget);
  });
}

/// One HD Box renewal sold at 30 for a cost of 25, plus one refunded after
/// the provider had performed it — with or without the owner's figures.
Map<String, Object?> _payload({required bool costs}) {
  Map<String, Object?> bucket(int count, String amount, String cost) => {
    'count': count,
    'amount': amount,
    if (costs) 'cost': cost,
  };
  final figures = <String, Object?>{
    'provider': 'hdbox',
    'count': 1,
    'sold': '30.00',
    if (costs) 'cost': '25.00',
    if (costs) 'margin': '5.00',
    'delivered': bucket(1, '30.00', '25.00'),
    'awaiting': bucket(0, '0.00', '0.00'),
    'unknown': bucket(0, '0.00', '0.00'),
    'refunded': bucket(1, '30.00', '25.00'),
    'refunded_after_delivery': {'count': 1, if (costs) 'cost': '25.00'},
  };
  return {
    'providers': [figures],
    'totals': figures,
    'transactions': [
      {
        'id': 1,
        'provider': 'hdbox',
        'kind': 'recharge',
        'order_id': 41,
        'receipt_number': 'R-41',
        'subscriber_ref': '210906803499',
        'option_label': '1 month',
        'price': '30.00',
        if (costs) 'cost': '25.00',
        'refunded_amount': '0.00',
        'status': 'confirmed',
        'bucket': 'delivered',
      },
    ],
  };
}

Future<void> _pump(
  WidgetTester tester,
  SessionIntegrations integrations,
) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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
        body: SingleChildScrollView(
          child: SessionIntegrationsSection(integrations: integrations),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
