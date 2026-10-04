import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/tracking/unit_pick_sheet.dart';

/// The shared "which handsets are leaving" sheet: exact counts, one article
/// per document, and a scan that can reach past the first page.
void main() {
  testWidgets('a handset ticked on one line cannot also leave on another', (
    tester,
  ) async {
    final loader = _Loader();
    final result = await _open(
      tester,
      loader,
      lines: const [
        UnitPickLine(key: 1, title: 'السطر الأول', count: 1, variantId: 5),
        UnitPickLine(key: 2, title: 'السطر الثاني', count: 1, variantId: 5),
      ],
    );

    await tester.tap(find.text('A-1').first);
    await tester.pumpAndSettle();
    // Same product on the second line: the ticked handset is not offered there.
    await tester.tap(find.text('A-1').last);
    await tester.pumpAndSettle();
    expect(find.text('1 من 1'), findsOneWidget);
    expect(find.text('0 من 1'), findsOneWidget);

    await tester.tap(find.text('A-2').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'تأكيد'));
    await tester.pumpAndSettle();

    expect(await result, {
      1: [1],
      2: [2],
    });
  });

  testWidgets('no more handsets than the line moves', (tester) async {
    final loader = _Loader();
    final result = await _open(
      tester,
      loader,
      lines: const [
        UnitPickLine(key: 1, title: 'هاتف', count: 1, variantId: 5),
      ],
    );

    await tester.tap(find.text('A-1'));
    await tester.tap(find.text('A-2'));
    await tester.pumpAndSettle();

    expect(find.text('1 من 1'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'تأكيد'));
    await tester.pumpAndSettle();
    expect(await result, {
      1: [1],
    });
  });

  testWidgets('a scan past the first page asks the server for it', (
    tester,
  ) async {
    final loader = _Loader();
    final result = await _open(
      tester,
      loader,
      lines: const [
        UnitPickLine(key: 1, title: 'هاتف', count: 1, variantId: 5),
      ],
    );

    await tester.enterText(find.byType(TextField), 'FAR-9');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(loader.codes, ['FAR-9']);
    expect(find.text('1 من 1'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'تأكيد'));
    await tester.pumpAndSettle();
    expect(await result, {
      1: [99],
    });
  });

  testWidgets('an unknown scan says so and ticks nothing', (tester) async {
    final loader = _Loader();
    await _open(
      tester,
      loader,
      lines: const [
        UnitPickLine(key: 1, title: 'هاتف', count: 1, variantId: 5),
      ],
    );

    await tester.enterText(find.byType(TextField), 'NOPE');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      find.text('لا يوجد جهاز متاح بهذا المعرّف ضمن هذه الأسطر.'),
      findsOne,
    );
    expect(find.text('0 من 1'), findsOneWidget);
  });
}

class _Loader {
  final List<String> codes = [];

  Future<Result<StockUnitPage>> call(int variantId, {String code = ''}) async {
    if (code.isNotEmpty) {
      codes.add(code);
      return Ok(
        StockUnitPage(
          units: [
            if (code == 'FAR-9')
              StockUnit(id: 99, variantId: variantId, code: 'FAR-9'),
          ],
        ),
      );
    }
    return Ok(
      StockUnitPage(
        units: [
          StockUnit(id: 1, variantId: variantId, code: 'A-1'),
          StockUnit(id: 2, variantId: variantId, code: 'A-2'),
        ],
      ),
    );
  }
}

Future<Future<Map<int, List<int>>?>> _open(
  WidgetTester tester,
  _Loader loader, {
  required List<UnitPickLine> lines,
}) async {
  late Future<Map<int, List<int>>?> result;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () {
              result = showUnitPickSheet(
                context,
                title: 'حدّد الأجهزة',
                message: 'رسالة',
                confirmLabel: 'تأكيد',
                lines: lines,
                loadUnits: loader.call,
              );
            },
            child: const Text('افتح'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('افتح'));
  await tester.pumpAndSettle();
  return result;
}
