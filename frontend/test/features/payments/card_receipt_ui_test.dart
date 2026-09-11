import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/register_session_summary.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/features/register_sessions/views/card_receipt_verification_section.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/payments/card_receipt_status.dart';

void main() {
  group('CardReceiptStatus', () {
    test('reads the backend vocabulary', () {
      expect(CardReceiptStatus.parse('verified'), CardReceiptStatus.verified);
      expect(CardReceiptStatus.parse('pending'), CardReceiptStatus.pending);
      expect(CardReceiptStatus.parse('flagged'), CardReceiptStatus.flagged);
      expect(
        CardReceiptStatus.parse('unavailable'),
        CardReceiptStatus.unavailable,
      );
      expect(
        CardReceiptStatus.parse('no_receipt'),
        CardReceiptStatus.noReceipt,
      );
    });

    test('an unknown or missing status shows no badge', () {
      expect(CardReceiptStatus.parse(null), CardReceiptStatus.none);
      expect(CardReceiptStatus.parse('something-new'), CardReceiptStatus.none);
      expect(CardReceiptStatus.none.isVisible, isFalse);
    });

    test('the worst state wins, so a problem cannot hide behind a tick', () {
      expect(
        CardReceiptStatus.worstOf([
          CardReceiptStatus.verified,
          CardReceiptStatus.flagged,
        ]),
        CardReceiptStatus.flagged,
      );
      expect(
        CardReceiptStatus.worstOf([
          CardReceiptStatus.verified,
          CardReceiptStatus.pending,
        ]),
        CardReceiptStatus.pending,
      );
      expect(CardReceiptStatus.worstOf(const []), CardReceiptStatus.none);
    });
  });

  group('SalePaymentCardReceipt', () {
    test('keeps every raw field the provider sent', () {
      final receipt = SalePaymentCardReceipt.fromJson(const {
        'provider': 'moamalat',
        'amount': '8.50',
        'raw_fields': {
          'CardHolder': 'QARQOOM SALEH',
          'TerminalCity': 'MISURATA LY',
          'Blank': '',
          'Missing': null,
        },
      });

      expect(receipt.rawFields['CardHolder'], 'QARQOOM SALEH');
      expect(receipt.rawFields['TerminalCity'], 'MISURATA LY');
      // Empty values are noise in a reconciliation view, not data.
      expect(receipt.rawFields.containsKey('Blank'), isFalse);
      expect(receipt.rawFields.containsKey('Missing'), isFalse);
    });

    test('maps the backend verification state onto the shared vocabulary', () {
      CardReceiptStatus statusFor(String state) =>
          SalePaymentCardReceipt.fromJson({
            'verification_state': state,
          }).status;

      expect(statusFor('settled'), CardReceiptStatus.verified);
      expect(statusFor('pending'), CardReceiptStatus.pending);
      expect(statusFor('mismatch'), CardReceiptStatus.flagged);
      expect(statusFor('rejected'), CardReceiptStatus.flagged);
      expect(statusFor('unavailable'), CardReceiptStatus.unavailable);
    });

    test('a receipt stored before states existed still reads as verified', () {
      // It was checked at the counter against its own decoded payload.
      expect(
        SalePaymentCardReceipt.fromJson(const {'provider': 'moamalat'}).status,
        CardReceiptStatus.verified,
      );
    });

    test('only an https link counts as an original to re-open', () {
      expect(
        SalePaymentCardReceipt.fromJson(const {
          'source_url': 'https://rms.lpco.ly/RCP/Dwl/abc',
        }).hasOriginal,
        isTrue,
      );
      expect(
        SalePaymentCardReceipt.fromJson(const {}).hasOriginal,
        isFalse,
      );
    });
  });

  group('shift verification section', () {
    testWidgets('shows verified against the shift total', (tester) async {
      await _pump(
        tester,
        const CardReceiptTotals(
          gross: 4000,
          verified: 2000,
          pending: 1000,
          flagged: 500,
          unavailable: 0,
          noReceipt: 500,
          pendingCount: 2,
          flaggedCount: 1,
        ),
      );

      // The headline is the comparison itself, not two separate numbers.
      expect(find.textContaining('2000.00'), findsWidgets);
      expect(find.textContaining('4000.00'), findsWidgets);
      // A flagged bucket outranks a pending one for the callout.
      expect(
        find.byKey(const ValueKey('session_card_receipts_attention')),
        findsOneWidget,
      );
    });

    testWidgets('a shift with no card takings draws nothing', (tester) async {
      await _pump(tester, CardReceiptTotals.empty);

      expect(find.byType(CardReceiptVerificationSection), findsOneWidget);
      // Present in the tree, but rendering no section heading of its own.
      expect(find.textContaining('موثّق'), findsNothing);
    });

    testWidgets('a fully verified shift reads as finished', (tester) async {
      await _pump(
        tester,
        const CardReceiptTotals(
          gross: 1200,
          verified: 1200,
          pending: 0,
          flagged: 0,
          unavailable: 0,
          noReceipt: 0,
          pendingCount: 0,
          flaggedCount: 0,
        ),
      );

      expect(
        find.byKey(const ValueKey('session_card_receipts_all_verified')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session_card_receipts_attention')),
        findsNothing,
      );
    });

    testWidgets('pending money is reported when nothing is flagged', (
      tester,
    ) async {
      await _pump(
        tester,
        const CardReceiptTotals(
          gross: 300,
          verified: 100,
          pending: 200,
          flagged: 0,
          unavailable: 0,
          noReceipt: 0,
          pendingCount: 3,
          flaggedCount: 0,
        ),
      );

      expect(
        find.byKey(const ValueKey('session_card_receipts_pending')),
        findsOneWidget,
      );
    });
  });
}

Future<void> _pump(WidgetTester tester, CardReceiptTotals totals) async {
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
          child: CardReceiptVerificationSection(totals: totals),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
