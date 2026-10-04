import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/product_image_viewer.dart';

Widget _host(List<String> urls) {
  return MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showProductImageViewer(
              context,
              imageUrls: urls,
              title: 'قهوة تركية',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('opens full screen and closes on Escape', (tester) async {
    await tester.pumpWidget(_host(['https://shop.test/a.png']));
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(ProductImageViewer), findsOneWidget);
    expect(find.text('قهوة تركية'), findsOneWidget);
    expect(find.byTooltip('إغلاق'), findsOneWidget);
    // A single image has no counter or step buttons.
    expect(find.text('1 / 1'), findsNothing);
    expect(find.byTooltip('الصورة التالية'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ProductImageViewer), findsNothing);
  });

  testWidgets('steps between several images', (tester) async {
    await tester.pumpWidget(
      _host(['https://shop.test/a.png', 'https://shop.test/b.png']),
    );
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tap(find.byTooltip('الصورة التالية'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2 / 2'), findsOneWidget);

    await tester.tap(find.byTooltip('إغلاق'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ProductImageViewer), findsNothing);
  });

  testWidgets('does nothing without a usable image', (tester) async {
    await tester.pumpWidget(_host(['  ']));
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ProductImageViewer), findsNothing);
  });
}
