import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/stock_count.dart';
import 'package:pointy_frontend/src/features/stock_count/views/stock_count_counting_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

const _session = StockCount(
  id: 1,
  countNumber: 'SC-1',
  status: StockCountStatus.inProgress,
  scope: StockCountScope.full,
  expectedLineCount: 48,
  countedLineCount: 21,
  varianceLineCount: 0,
);

const _variant = ProductVariant(
  id: 5,
  productId: 1,
  sku: 'SKU-5',
  displayName: 'صنف للاختبار',
  unitPrice: 1,
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

StockCountCountingBody _body({ProductVariant? variant, String input = ''}) {
  return StockCountCountingBody(
    session: _session,
    counted: 21,
    total: 48,
    progress: 21 / 48,
    variant: variant,
    input: input,
    onSearchChanged: (_) {},
    onPickVariant: (_) {},
    onInputChanged: (_) {},
    onSubmitInput: () {},
    onCamera: () {},
    onDigit: (_) {},
    onDecimal: () {},
    onBackspace: () {},
    onClear: () {},
    footer: const SizedBox.shrink(),
  );
}

void main() {
  testWidgets('shows the current item, its count, and the keypad', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_wrap(_body(variant: _variant, input: '18')));
    await tester.pumpAndSettle();

    expect(find.text('صنف للاختبار'), findsOneWidget);
    expect(find.text('18'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('payment_keypad_digit_5')),
      findsOneWidget,
    );
  });

  testWidgets('shows the scan prompt and no keypad when nothing is selected', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_wrap(_body()));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.qr_code_scanner_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('payment_keypad_digit_5')), findsNothing);
  });

  testWidgets('splits into item and keypad panes on a wide surface', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_wrap(_body(variant: _variant, input: '7')));
    await tester.pumpAndSettle();

    expect(find.text('صنف للاختبار'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('payment_keypad_digit_5')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
