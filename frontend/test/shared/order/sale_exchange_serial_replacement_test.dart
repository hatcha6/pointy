import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/data/repositories/tracked_stock_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';
import 'package:pointy_frontend/src/shared/order/pointy_quantity_stepper.dart';
import 'package:pointy_frontend/src/shared/order/sale_order_details_content.dart';

/// The shelf the till's picker reads: two handsets of the replacement model,
/// one carrying its own asking price.
class _FakeTrackedStockRepository extends TrackedStockRepository {
  _FakeTrackedStockRepository() : super(PosApiService());

  final requestedVariants = <int>[];

  @override
  Future<Result<StockUnitPage>> loadSellableUnits({
    required int variantId,
  }) async {
    requestedVariants.add(variantId);
    return Ok(
      const StockUnitPage(
        units: [
          StockUnit(
            id: 501,
            variantId: 40,
            code: '356938035643809',
            listPrice: 950,
          ),
          StockUnit(id: 502, variantId: 40, code: '356938035643817'),
        ],
        count: 2,
      ),
    );
  }
}

const _serialOption = ExchangeProductOption(
  variantId: 40,
  label: 'آيفون 13',
  unitPrice: 1000,
  trackingMode: TrackingMode.serial,
);

SaleOrder _paidInvoice() {
  return SaleOrder(
    id: 9,
    receiptNumber: 'R20261004000009',
    status: 'paid',
    lines: [
      SaleOrderLine(
        id: 1,
        productId: 4,
        variantId: 4,
        productName: 'سامسونج A15',
        quantity: 1,
        returnedQuantity: 0,
        returnableQuantity: 1,
        unitPrice: 900,
        total: 900,
      ),
    ],
    payments: const [],
    subtotal: 900,
    total: 900,
    paymentStatus: 'paid',
  );
}

Widget _host({
  required TrackedStockRepository? repository,
  required ValueChanged<SaleExchangeDraft> onDraft,
}) {
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
    home: Scaffold(
      body: SaleOrderDetailsContent(
        order: _paidInvoice(),
        popOnSuccessfulAdjustment: false,
        onExchange: (order, draft) async {
          onDraft(draft);
          return true;
        },
        onProductSearch: (query) async => const [_serialOption],
        trackedStockRepository: repository,
      ),
    ),
  );
}

Future<void> _openDialogAndSearch(WidgetTester tester) async {
  await tester.tap(find.text('استبدال'));
  await tester.pumpAndSettle();
  // Return the one handset on the invoice.
  await tester.tap(find.byIcon(Icons.add).first);
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextField, 'ابحث عن منتج بديل'),
    'آيفون',
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

/// Taps the serial result's add button and picks [code] inside the sheet —
/// inside it, so a tap that missed could not fall on the barrier, close the
/// sheet empty-handed and pass anyway.
Future<void> _pickFromSheet(WidgetTester tester, String code) async {
  await tester.tap(find.byIcon(Icons.add).last);
  await tester.pumpAndSettle();
  expect(find.text('اختر الجهاز — آيفون 13'), findsOneWidget);
  await tester.tap(
    find.descendant(of: find.byType(BottomSheet), matching: find.text(code)),
  );
  await tester.pumpAndSettle();
  expect(find.byType(BottomSheet), findsNothing);
}

void main() {
  group('SaleExchangeReplacementLineDraft.toJson', () {
    test('names the picked handset only when there is one', () {
      expect(
        const SaleExchangeReplacementLineDraft(
          variantId: 40,
          quantity: 1,
          stockUnitId: 501,
        ).toJson(),
        {
          'variant': 40,
          'quantity': '1',
          'stock_units': [501],
        },
      );
      expect(
        const SaleExchangeReplacementLineDraft(
          variantId: 7,
          quantity: 2,
        ).toJson(),
        {'variant': 7, 'quantity': '2'},
      );
    });
  });

  testWidgets('a serial replacement is picked by IMEI, one per line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _FakeTrackedStockRepository();
    SaleExchangeDraft? sent;
    await tester.pumpWidget(
      _host(repository: repository, onDraft: (draft) => sent = draft),
    );
    await _openDialogAndSearch(tester);

    // Adding the phone opens the till's picker instead of counting one.
    await _pickFromSheet(tester, '356938035643809');
    expect(repository.requestedVariants, [40]);

    // The row names the handset, is priced at its own asking price, and has no
    // quantity to step: the only stepper left is the returned line's own.
    expect(find.text('356938035643809'), findsOneWidget);
    expect(find.text(formatMoney(950)), findsOneWidget);
    expect(find.byType(PointyQuantityStepper), findsOneWidget);
    expect(find.text('على العميل دفع ${formatMoney(50)}'), findsOneWidget);

    // Picking the same handset again keeps the one line.
    await _pickFromSheet(tester, '356938035643809');
    expect(find.text('356938035643809'), findsOneWidget);

    // A second handset is a line of its own, at the product's price.
    await _pickFromSheet(tester, '356938035643817');
    expect(find.text('356938035643817'), findsOneWidget);
    expect(find.byType(PointyQuantityStepper), findsOneWidget);
    expect(find.text('على العميل دفع ${formatMoney(1050)}'), findsOneWidget);

    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();

    expect(
      sent!.replacementLines.map((line) => (line.stockUnitId, line.quantity)),
      [(501, 1), (502, 1)],
    );
    expect(sent!.toJson()['replacement_lines'], [
      {
        'variant': 40,
        'quantity': '1',
        'stock_units': [501],
      },
      {
        'variant': 40,
        'quantity': '1',
        'stock_units': [502],
      },
    ]);
  });

  testWidgets('without the shelf a serial replacement cannot be added', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_host(repository: null, onDraft: (_) {}));
    await _openDialogAndSearch(tester);

    final add = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.add).last,
    );
    expect(add.onPressed, isNull);
  });
}
