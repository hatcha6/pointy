import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/ai_ui_preview_surfaces.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/features/ai/ui/ai_surface_host.dart';
import 'package:pointy_frontend/src/features/ai/ui/ai_surface_view.dart';
import 'package:pointy_frontend/src/features/ai/ui/pointy_ai_catalog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() {
  test('the POS cards are in the catalog', () {
    expect(
      PointyAiCatalog.itemNames,
      containsAll(['ProductCard', 'CustomerCard', 'SalesSummaryCard']),
    );
  });

  for (final width in const [360.0, 1024.0]) {
    for (final dark in const [false, true]) {
      testWidgets('POS cards render at $width (dark: $dark)', (tester) async {
        tester.view.physicalSize = Size(width, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final host = AiSurfaceHost();
        addTearDown(host.dispose);
        final surface = posCardsSurface();
        host.apply(surface);

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
            theme: dark ? PointyTheme.dark() : PointyTheme.light(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: AiSurfaceView(host: host, surface: surface),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('قهوة تركي ٢٥٠غ'), findsWidgets);
        // Six days of cover is a running-out warning, not a quiet number.
        expect(find.text('قد ينفد قريبًا'), findsOneWidget);
        // 640 owed against a 500 limit is flagged.
        expect(find.text('تجاوز الحد الائتماني'), findsOneWidget);
        expect(find.text('الأكثر مبيعًا'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
