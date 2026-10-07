import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/receipt_capture.dart';
import 'package:pointy_frontend/src/data/models/unit_attribute.dart';
import 'package:pointy_frontend/src/features/inventory/views/batch_capture_sheet.dart';
import 'package:pointy_frontend/src/features/inventory/views/unit_capture_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/tracking/unit_attribute_catalog.dart';

/// The two sheets a receiver fills with the goods in front of them.
void main() {
  group('the scan loop', () {
    testWidgets('a mistyped IMEI is questioned once, then taken as typed', (
      tester,
    ) async {
      final result = await _openUnits(
        tester,
        expectedCount: 1,
        identifierKind: 'imei',
        script: (tester) async {
          await _scan(tester, '490154203237519');
          // Questioned, not added: the field keeps it for a re-scan.
          expect(find.textContaining('خانة التحقق'), findsOneWidget);
          expect(find.text('1 / 1'), findsNothing);
          // The box says exactly that: Enter again takes it.
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(find.text('1 / 1'), findsOneWidget);
        },
      );
      expect(result!.single.code, '490154203237519');
      expect(result.single.identifierKind, 'imei');
    });

    testWidgets('a good IMEI goes straight in', (tester) async {
      await _openUnits(
        tester,
        expectedCount: 2,
        identifierKind: 'imei',
        confirm: false,
        script: (tester) async {
          await _scan(tester, '490154203237518');
          expect(find.textContaining('خانة التحقق'), findsNothing);
          expect(find.text('1 / 2'), findsOneWidget);
        },
      );
    });

    testWidgets('a serial-in-lot loop names the lot it scans into', (
      tester,
    ) async {
      await _openUnits(
        tester,
        expectedCount: 1,
        lot: ReceiptBatchCapture(
          code: 'NV-24K118',
          quantity: 1,
          expiryDate: DateTime(2027, 10, 31),
        ),
        confirm: false,
        script: (tester) async {
          expect(
            find.byKey(const ValueKey('unit-capture-lot-banner')),
            findsOneWidget,
          );
          expect(find.textContaining('NV-24K118'), findsOneWidget);
        },
      );
    });

    testWidgets('a receiver who may price sets each handset\'s own price', (
      tester,
    ) async {
      final result = await _openUnits(
        tester,
        expectedCount: 1,
        canSetPrice: true,
        script: (tester) async {
          await _scan(tester, 'SN-1');
          // Labelled, not a bare icon: there is no checklist, only a price.
          await tester.tap(
            find.byKey(const ValueKey('unit-capture-details-SN-1')),
          );
          await tester.pumpAndSettle();
          expect(find.text('ينتهي ضمان هذا الجهاز في'), findsNothing);
          await tester.enterText(
            find.byKey(const ValueKey('unit-details-list-price')),
            '2600',
          );
          await tester.tap(find.byKey(const ValueKey('unit-details-save')));
          await tester.pumpAndSettle();
          expect(find.textContaining('سعر البيع 2600.00'), findsOneWidget);
        },
      );
      expect(result!.single.listPrice, 2600);
      expect(result.single.toJson()['list_price'], '2600.00');
    });

    testWidgets('without the permission no price or warranty is offered', (
      tester,
    ) async {
      await _openUnits(
        tester,
        expectedCount: 1,
        confirm: false,
        script: (tester) async {
          await _scan(tester, 'SN-1');
          // No checklist and no price: nothing to open per handset.
          expect(
            find.byKey(const ValueKey('unit-capture-details-SN-1')),
            findsNothing,
          );
        },
      );
    });

    testWidgets('a required checklist field holds the sheet until filled', (
      tester,
    ) async {
      final result = await _openUnits(
        tester,
        expectedCount: 1,
        assetTypeId: 3,
        definitions: const [
          UnitAttributeDefinition(
            key: 'battery_health',
            label: 'صحة البطارية',
            dataType: UnitAttributeType.percent,
            isRequired: true,
          ),
        ],
        script: (tester) async {
          await _scan(tester, 'SN-1');
          expect(
            find.byKey(const ValueKey('unit-capture-blocked')),
            findsOneWidget,
          );
          expect(_confirm(tester).onPressed, isNull);

          await tester.tap(
            find.byKey(const ValueKey('unit-capture-details-SN-1')),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('unit-attribute-battery_health')),
            '88',
          );
          await tester.tap(find.byKey(const ValueKey('unit-details-save')));
          await tester.pumpAndSettle();

          expect(
            find.byKey(const ValueKey('unit-capture-blocked')),
            findsNothing,
          );
          expect(find.text('الحالة مسجّلة لـ 1 من 1'), findsOneWidget);
        },
      );
      expect(result!.single.attributes, {'battery_health': 88});
    });

    testWidgets(
      'split costs must still add up when handsets are owed for later',
      (tester) async {
        await _openUnits(
          tester,
          expectedCount: 3,
          allowCaptureLater: true,
          confirm: false,
          script: (tester) async {
            await _scan(tester, 'SN-1');
            await tester.tap(find.byType(Switch));
            await tester.pumpAndSettle();
            // The unscanned two are booked at the line's 1950, so one handset
            // cannot carry 3000 on its own.
            await tester.enterText(
              find.descendant(
                of: find.byKey(const ValueKey('unit-capture-cost-SN-1')),
                matching: find.byType(EditableText),
              ),
              '3000',
            );
            await tester.pumpAndSettle();
            expect(_confirm(tester).onPressed, isNull);
            expect(
              find.byKey(const ValueKey('unit-capture-blocked')),
              findsOneWidget,
            );
          },
        );
      },
    );
  });

  group('the lot sheet', () {
    testWidgets('lots that must expire are each asked for a date', (
      tester,
    ) async {
      final result = await _openLots(
        tester,
        expiryRequired: true,
        script: (tester) async {
          await tester.enterText(find.byType(TextFormField).first, 'L-A');
          await tester.pumpAndSettle();
          expect(find.text('تاريخ الصلاحية مطلوب'), findsOneWidget);
          expect(_lotConfirm(tester).onPressed, isNull);

          await tester.tap(find.widgetWithText(OutlinedButton, '+12ش'));
          await tester.pumpAndSettle();
          expect(find.text('تاريخ الصلاحية مطلوب'), findsNothing);
        },
      );
      expect(result!.single.expiryDate, isNotNull);
    });

    testWidgets('lots of goods that never expire need no date', (tester) async {
      final result = await _openLots(
        tester,
        script: (tester) async {
          await tester.enterText(find.byType(TextFormField).first, 'BATCH-07');
          await tester.pumpAndSettle();
          expect(find.text('تاريخ الصلاحية مطلوب'), findsNothing);
          expect(_lotConfirm(tester).onPressed, isNotNull);
        },
      );
      expect(result!.single.code, 'BATCH-07');
      expect(result.single.expiryDate, isNull);
    });
  });
}

FilledButton _confirm(WidgetTester tester) => tester.widget<FilledButton>(
  find.byKey(const ValueKey('unit-capture-confirm')),
);

FilledButton _lotConfirm(WidgetTester tester) => tester.widget<FilledButton>(
  find.byKey(const ValueKey('batch-capture-confirm')),
);

Future<void> _scan(WidgetTester tester, String code) async {
  await tester.enterText(
    find.byKey(const ValueKey('unit-capture-input')),
    code,
  );
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

Future<List<ReceiptUnitCapture>?> _openUnits(
  WidgetTester tester, {
  required int expectedCount,
  required Future<void> Function(WidgetTester tester) script,
  String identifierKind = '',
  ReceiptBatchCapture? lot,
  bool canSetPrice = false,
  bool allowCaptureLater = false,
  int? assetTypeId,
  List<UnitAttributeDefinition> definitions = const [],
  bool confirm = true,
}) async {
  List<ReceiptUnitCapture>? result;
  await _pumpHost(
    tester,
    catalog: UnitAttributeCatalog((_) async => Ok(definitions)),
    onOpen: (context) async {
      result = await showUnitCaptureSheet(
        context,
        productLabel: 'آيفون 13 برو مستعمل',
        expectedCount: expectedCount,
        lineUnitCost: 1950,
        identifierKind: identifierKind,
        lot: lot,
        canSetPrice: canSetPrice,
        allowCaptureLater: allowCaptureLater,
        assetTypeId: assetTypeId,
      );
    },
  );
  await script(tester);
  if (confirm) {
    await tester.tap(find.byKey(const ValueKey('unit-capture-confirm')));
    await tester.pumpAndSettle();
  }
  return result;
}

Future<List<ReceiptBatchCapture>?> _openLots(
  WidgetTester tester, {
  required Future<void> Function(WidgetTester tester) script,
  bool expiryRequired = false,
}) async {
  List<ReceiptBatchCapture>? result;
  await _pumpHost(
    tester,
    onOpen: (context) async {
      result = await showBatchCaptureSheet(
        context,
        productLabel: 'دهان',
        expectedQuantity: 10,
        expiryRequired: expiryRequired,
      );
    },
  );
  await script(tester);
  await tester.tap(find.byKey(const ValueKey('batch-capture-confirm')));
  await tester.pumpAndSettle();
  return result;
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required Future<void> Function(BuildContext context) onOpen,
  UnitAttributeCatalog? catalog,
}) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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
      builder: catalog == null
          ? null
          : (context, child) => UnitAttributeCatalogScope(
              catalog: catalog,
              child: child ?? const SizedBox.shrink(),
            ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => onOpen(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
