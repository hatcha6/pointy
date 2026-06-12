import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/features/reports/views/reports_screen.dart';

import '../../../shared/fake_app_navigation.dart';

void main() {
  testWidgets('keeps report workspace usable on compact and wide widths', (
    tester,
  ) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    for (final size in [const Size(390, 900), const Size(1366, 900)]) {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;

      await tester.pumpWidget(const _ReportsTestApp());
      await tester.pumpAndSettle();

      expect(find.text('التقارير'), findsWidgets);
      expect(find.text('أنواع التقارير'), findsOneWidget);

      if (size.width < 900) {
        expect(find.text('معاينة PDF', skipOffstage: false), findsNothing);

        await tester.tap(find.text('ملخص المبيعات'));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('report_details_sheet')),
          findsOneWidget,
        );
        expect(find.text('معاينة PDF', skipOffstage: false), findsOneWidget);
      } else {
        expect(find.text('معاينة PDF', skipOffstage: false), findsOneWidget);
      }

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('shows report action progress and ignores duplicate taps', (
    tester,
  ) async {
    final completer = Completer<void>();
    var calls = 0;

    tester.view
      ..physicalSize = const Size(1366, 900)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _ReportsTestApp(
        onPreviewPdf: (_) {
          calls++;
          return completer.future;
        },
      ),
    );
    await tester.pumpAndSettle();

    final previewAction = find.text('معاينة PDF', skipOffstage: false);
    await tester.ensureVisible(previewAction);
    await tester.pumpAndSettle();

    await tester.tap(previewAction);
    await tester.pump();

    expect(calls, 1);
    expect(find.text('جارٍ تنفيذ معاينة PDF...'), findsOneWidget);

    await tester.tap(previewAction);
    await tester.pump();

    expect(calls, 1);

    completer.complete();
    await tester.pumpAndSettle();

    expect(find.text('جارٍ تنفيذ معاينة PDF...'), findsNothing);
  });

  testWidgets('shows a localized report action error', (tester) async {
    tester.view
      ..physicalSize = const Size(1366, 900)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _ReportsTestApp(
        onPrintReport: (_) async {
          throw Exception('print failed');
        },
      ),
    );
    await tester.pumpAndSettle();

    final printAction = find.text('طباعة', skipOffstage: false);
    await tester.ensureVisible(printAction);
    await tester.pumpAndSettle();

    await tester.tap(printAction);
    await tester.pumpAndSettle();

    expect(find.text('تعذر تنفيذ طباعة. حاول مرة أخرى.'), findsOneWidget);
  });
}

class _ReportsTestApp extends StatelessWidget {
  const _ReportsTestApp({this.onPreviewPdf, this.onPrintReport});

  final ReportActionCallback? onPreviewPdf;
  final ReportActionCallback? onPrintReport;

  @override
  Widget build(BuildContext context) {
    const user = PosUser(
      id: 1,
      username: 'manager',
      role: UserRole.manager,
      isActive: true,
    );

    return MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      home: ReportsScreen(
        capabilities: AuthorizationCapabilities.forUser(user),
        navigation: FakeAppNavigation(currentUser: user),
        onPreviewPdf: onPreviewPdf,
        onPrintReport: onPrintReport,
        onExportArchive: (_) async {},
      ),
    );
  }
}
