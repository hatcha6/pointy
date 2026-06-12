import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';

void main() {
  Future<BuildContext> pumpHost(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ar'),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              hostContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return hostContext;
  }

  group('showAdaptiveFormSurface', () {
    testWidgets('presents a bottom sheet below desktop widths', (tester) async {
      final context = await pumpHost(tester, 390);

      showAdaptiveFormSurface<void>(
        context: context,
        title: 'نموذج',
        builder: (_) => const Text('form-body'),
      );
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('form-body'), findsOneWidget);
      expect(find.text('نموذج'), findsOneWidget);
    });

    testWidgets('presents a centered dialog at desktop widths', (tester) async {
      final context = await pumpHost(tester, 1366);

      showAdaptiveFormSurface<void>(
        context: context,
        title: 'نموذج',
        builder: (_) => const Text('form-body'),
      );
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('form-body'), findsOneWidget);
      expect(find.text('نموذج'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('close button dismisses the desktop dialog', (tester) async {
      final context = await pumpHost(tester, 1366);

      showAdaptiveFormSurface<void>(
        context: context,
        title: 'نموذج',
        builder: (_) => const Text('form-body'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('form-body'), findsNothing);
    });

    testWidgets('presents an end-anchored side panel when requested', (
      tester,
    ) async {
      final context = await pumpHost(tester, 1366);

      showAdaptiveFormSurface<void>(
        context: context,
        title: 'نموذج',
        desktopPresentation: AdaptiveFormPresentation.sidePanel,
        builder: (_) => const Text('form-body'),
      );
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('form-body'), findsOneWidget);

      // RTL app: the end-anchored panel sits on the visual left half.
      final bodyCenter = tester.getCenter(find.text('form-body'));
      expect(bodyCenter.dx, lessThan(1366 / 2));
    });
  });
}
