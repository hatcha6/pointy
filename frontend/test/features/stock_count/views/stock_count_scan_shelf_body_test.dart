import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/stock_count.dart';
import 'package:pointy_frontend/src/data/models/stock_count_draft.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/features/stock_count/views/stock_count_counting_screen.dart';
import 'package:pointy_frontend/src/features/stock_count/views/stock_count_findings.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/features/pos/views/payment/pointy_keypad.dart';

const _session = StockCount(
  id: 1,
  countNumber: 'SC-1',
  status: StockCountStatus.inProgress,
  scope: StockCountScope.full,
  expectedLineCount: 6,
  countedLineCount: 2,
  varianceLineCount: 0,
);

const _serialized = ProductVariant(
  id: 5,
  productId: 1,
  sku: 'IPH-13',
  displayName: 'آيفون ١٣',
  unitPrice: 1800,
  trackingMode: TrackingMode.serial,
);

const _anonymous = ProductVariant(
  id: 6,
  productId: 2,
  sku: 'SUGAR',
  displayName: 'سكر',
  unitPrice: 5,
);

Widget _wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: PointyTheme.light(),
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('a serialized item shows no keypad at all', (tester) async {
    // §6.6: counting a *number* of serialized articles is meaningless, and a
    // keypad sitting there invites somebody to type "4".
    await tester.pumpWidget(
      _wrap(
        StockCountCountingBody(
          session: _session,
          counted: 2,
          total: 6,
          progress: 2 / 6,
          variant: _serialized,
          input: '',
          countsByScan: true,
          scannedForCurrent: 3,
          scans: const [
            StockCountScanResult(
              id: 1,
              code: '358240051111110',
              created: true,
              known: true,
              variantId: 5,
            ),
          ],
          onSearch: () {},
          onCamera: () {},
          onDigit: (_) {},
          onDecimal: () {},
          onBackspace: () {},
          onClear: () {},
          onScanIdentifier: (_) {},
          footer: const SizedBox.shrink(),
        ),
      ),
    );

    expect(find.byType(PointyKeypad), findsNothing);
    expect(find.text('358240051111110'), findsOneWidget);
  });

  testWidgets('an anonymous item still gets its keypad', (tester) async {
    await tester.pumpWidget(
      _wrap(
        StockCountCountingBody(
          session: _session,
          counted: 2,
          total: 6,
          progress: 2 / 6,
          variant: _anonymous,
          input: '8',
          onSearch: () {},
          onCamera: () {},
          onDigit: (_) {},
          onDecimal: () {},
          onBackspace: () {},
          onClear: () {},
          footer: const SizedBox.shrink(),
        ),
      ),
    );

    expect(find.byType(PointyKeypad), findsOneWidget);
  });

  testWidgets('the findings name each list rather than netting them', (
    tester,
  ) async {
    // A variance of −3 on a shelf of handsets is a number nobody can act on.
    await tester.pumpWidget(
      _wrap(
        const SingleChildScrollView(
          child: StockCountFindingsCard(
            findings: StockCountScanReconciliation(
              expected: 4,
              scanned: 3,
              missing: [
                StockCountFinding(code: 'GONE-1', variantName: 'آيفون ١٣'),
              ],
              unknown: [StockCountFinding(code: 'STRANGER')],
              relocated: [StockCountFinding(code: 'ELSEWHERE', detail: 'فرع')],
              resurrected: [],
              lots: [],
            ),
          ),
        ),
      ),
    );

    expect(find.text('GONE-1'), findsOneWidget);
    expect(find.text('STRANGER'), findsOneWidget);
    expect(find.text('ELSEWHERE'), findsOneWidget);
  });
}
