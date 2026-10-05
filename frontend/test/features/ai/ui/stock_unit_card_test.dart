import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/ai_chat.dart';
import 'package:pointy_frontend/src/features/ai/ui/ai_surface_action.dart';
import 'package:pointy_frontend/src/features/ai/ui/ai_surface_host.dart';
import 'package:pointy_frontend/src/features/ai/ui/ai_surface_view.dart';
import 'package:pointy_frontend/src/features/ai/ui/pointy_ai_catalog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/ai_deep_link.dart';

import 'package:pointy_frontend/dev/ai_ui_preview_surfaces.dart';

Widget _host(AiSurfaceHost host, AiUiSurface surface, {bool dark = false}) {
  return MaterialApp(
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
  );
}

void main() {
  test('the unit card is in the catalog', () {
    expect(PointyAiCatalog.itemNames, contains('StockUnitCard'));
  });

  for (final width in const [390.0, 1366.0]) {
    for (final dark in const [false, true]) {
      testWidgets('full, stopped and compact cards render at $width '
          '(dark: $dark)', (tester) async {
        tester.view.physicalSize = Size(width, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final host = AiSurfaceHost();
        addTearDown(host.dispose);
        final surface = AiUiSurface(
          surfaceId: 'units',
          components: stockUnitCardExample(),
          data: const {},
        );
        host.apply(surface);

        await tester.pumpWidget(_host(host, surface, dark: dark));
        await tester.pumpAndSettle();

        expect(find.text('آيفون 13 · 128GB أزرق'), findsOneWidget);
        expect(find.text('الدفعة موقوفة عن البيع'), findsOneWidget);
        expect(find.text('أمانة'), findsOneWidget);
        expect(find.text('134 يومًا على الرف'), findsOneWidget);
        // A stopped pack's card shows no asking price.
        expect(find.textContaining('18.50'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('tapping a card opens that unit by its deep link', (
    tester,
  ) async {
    final host = AiSurfaceHost();
    addTearDown(host.dispose);
    final surface = AiUiSurface(
      surfaceId: 'unit',
      components: const [
        {
          'id': 'root',
          'component': 'StockUnitCard',
          'unitId': 41,
          'code': '358240051111110',
          'product': 'آيفون 13',
          'status': 'in_stock',
          'price': 1450,
        },
      ],
      data: const {},
    );
    host.apply(surface);
    final actions = <AiSurfaceAction>[];
    final subscription = host.actions.listen(actions.add);
    addTearDown(subscription.cancel);

    await tester.pumpWidget(_host(host, surface));
    await tester.pumpAndSettle();
    await tester.tap(find.text('آيفون 13'));
    await tester.pumpAndSettle();

    expect(actions, hasLength(1));
    expect(actions.single.kind, AiSurfaceActionKind.navigate);
    expect(actions.single.link, 'pointy://stock-unit/41');
    expect(
      AiDeepLink.tryParse(actions.single.link!),
      const AiEntityLink('stock-unit', 41),
    );
  });
}
