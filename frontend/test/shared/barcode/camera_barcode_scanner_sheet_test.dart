import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/barcode/camera_barcode_scanner_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() {
  testWidgets('a denied camera permission is named as a permission problem', (
    tester,
  ) async {
    await _pumpErrorView(
      tester,
      errorCode: MobileScannerErrorCode.permissionDenied,
    );

    final l10n = _l10n(tester);
    expect(find.text(l10n.cameraScannerPermissionError), findsOneWidget);
    expect(find.text(l10n.cameraScannerNoCameraError), findsNothing);
    expect(find.text(l10n.cameraScannerGenericError), findsNothing);
  });

  testWidgets('a device with no camera is not blamed on permissions', (
    tester,
  ) async {
    await _pumpErrorView(tester, errorCode: MobileScannerErrorCode.unsupported);

    final l10n = _l10n(tester);
    expect(find.text(l10n.cameraScannerNoCameraError), findsOneWidget);
    expect(find.text(l10n.cameraScannerPermissionError), findsNothing);
  });

  testWidgets('any other camera failure gets the generic wording', (
    tester,
  ) async {
    await _pumpErrorView(
      tester,
      errorCode: MobileScannerErrorCode.genericError,
    );

    final l10n = _l10n(tester);
    expect(find.text(l10n.cameraScannerGenericError), findsOneWidget);
    expect(find.text(l10n.cameraScannerPermissionError), findsNothing);
  });

  testWidgets('a retryable failure offers a retry that calls back', (
    tester,
  ) async {
    var retries = 0;
    await _pumpErrorView(
      tester,
      errorCode: MobileScannerErrorCode.permissionDenied,
      onRetry: () => retries++,
    );

    final l10n = _l10n(tester);
    final retry = find.ancestor(
      of: find.text(l10n.retryButton),
      matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
    );
    expect(retry, findsOneWidget);
    expect(tester.widget<OutlinedButton>(retry).onPressed, isNotNull);

    await tester.tap(retry);
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets(
    'a missing camera offers no retry, because retrying cannot help',
    (tester) async {
      await _pumpErrorView(
        tester,
        errorCode: MobileScannerErrorCode.unsupported,
      );

      expect(find.text(_l10n(tester).retryButton), findsNothing);
    },
  );

  testWidgets('the quantity stepper labels both of its icon-only buttons', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      CameraScannerQuantityStepper(value: 3, onChanged: (_) {}),
    );

    final l10n = _l10n(tester);
    final tooltips = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .map((button) => button.tooltip)
        .toList();

    expect(tooltips, [l10n.removeOneTooltip, l10n.addOneTooltip]);
  });

  testWidgets('the stepper still explains itself at its lower bound', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      CameraScannerQuantityStepper(value: 1, onChanged: (_) {}),
    );

    final l10n = _l10n(tester);
    final decrement = tester.widget<IconButton>(find.byType(IconButton).first);
    expect(decrement.onPressed, isNull);
    expect(decrement.tooltip, l10n.removeOneTooltip);
  });
}

AppLocalizations _l10n(WidgetTester tester) {
  return AppLocalizations.of(tester.element(find.byType(Directionality).last))!;
}

Future<void> _pumpErrorView(
  WidgetTester tester, {
  required MobileScannerErrorCode errorCode,
  VoidCallback? onRetry,
}) {
  return _pumpSheet(
    tester,
    CameraScannerErrorView(errorCode: errorCode, onRetry: onRetry ?? () {}),
  );
}

Future<void> _pumpSheet(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Material(
          child: Center(child: SizedBox(width: 390, height: 640, child: child)),
        ),
      ),
    ),
  );
  await tester.pump();
}
