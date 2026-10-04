import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/stock_batch.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_order_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/role_fixtures.dart';

/// A supplier return of a serialised line names the handsets that go back.
///
/// The server refuses a serial line that names none — it will not guess which
/// IMEI left — so before this the return dialog could only ever earn a 400 on
/// a phone shop's order. The buyer now picks the handsets, from the shelf the
/// delivery landed on, and the request carries their ids.
void main() {
  testWidgets('a serial return asks which handset and sends its id', (
    tester,
  ) async {
    final repository = await _pumpOrder(tester);

    await _openReturn(tester);
    // The serialised line steps whole handsets and says what comes next.
    expect(find.textContaining('تُحدَّد الأجهزة بعد التأكيد'), findsOneWidget);
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();

    // The pick sheet lists what is standing where the delivery landed.
    expect(find.text('حدّد الأجهزة المُرجَعة للمورد'), findsOneWidget);
    expect(repository.requestedWarehouses, [7]);
    expect(find.text('SN-1'), findsOneWidget);
    expect(find.text('SN-2'), findsOneWidget);

    // Nothing is sent until the count is met.
    await tester.tap(find.widgetWithText(FilledButton, 'تأكيد'));
    await tester.pumpAndSettle();
    expect(repository.returned, isNull);

    await tester.tap(find.text('SN-2'));
    await tester.pumpAndSettle();
    expect(find.text('1 من 1'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'تأكيد'));
    await tester.pumpAndSettle();

    final sent = repository.returned!.toJson()['lines']! as List<Object?>;
    expect(sent, [
      {
        'line': 1,
        'quantity': '1.000',
        'units': [102],
      },
    ]);
  });

  testWidgets('a scanned identifier ticks its handset', (tester) async {
    final repository = await _pumpOrder(tester);

    await _openReturn(tester);
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'sn 1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('1 من 1'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'تأكيد'));
    await tester.pumpAndSettle();

    final sent = repository.returned!.toJson()['lines']! as List<Object?>;
    expect((sent.single! as Map)['units'], [101]);
  });

  testWidgets('backing out of the pick sends nothing', (tester) async {
    final repository = await _pumpOrder(tester);

    await _openReturn(tester);
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('SN-1'))).pop();
    await tester.pumpAndSettle();

    expect(repository.returned, isNull);
  });

  testWidgets('an exchange names the handset that goes and can scan the one '
      'that comes', (tester) async {
    final repository = await _pumpOrder(tester);

    await tester.tap(find.text('إجراءات أخرى'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('استبدال'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();
    // The replacement mirrors the handset going out: it can be scanned.
    expect(find.byTooltip('امسح معرّفات البديل'), findsOneWidget);
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('SN-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'تأكيد'));
    await tester.pumpAndSettle();

    final sent = repository.exchanged!.toJson();
    expect(sent['lines'], [
      {
        'line': 1,
        'quantity': '1.000',
        'units': [101],
      },
    ]);
    // Not scanned: it waits on the missing-identifier list, server-side.
    final replacement =
        (sent['replacement_lines']! as List<Object?>).single! as Map;
    expect(replacement.containsKey('units'), isFalse);
  });

  testWidgets('a serial-and-lot replacement is held until its lot is scanned', (
    tester,
  ) async {
    final repository = await _pumpOrder(tester, mode: 'serial_batch');

    await tester.tap(find.text('إجراءات أخرى'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('استبدال'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();

    expect(
      find.text('البديل صنف مسلسل بدفعة: امسح رقم الدفعة قبل التأكيد.'),
      findsOneWidget,
    );
    expect(find.text('حدّد الأجهزة المُرجَعة للمورد'), findsNothing);
    expect(repository.exchanged, isNull);
  });

  testWidgets('a quantity line goes back without a pick', (tester) async {
    final repository = await _pumpOrder(tester);

    await _openReturn(tester);
    await tester.tap(find.byTooltip('إضافة عنصر').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();

    expect(find.text('حدّد الأجهزة المُرجَعة للمورد'), findsNothing);
    final sent = repository.returned!.toJson()['lines']! as List<Object?>;
    expect(sent, [
      {'line': 2, 'quantity': '1.000'},
    ]);
  });

  testWidgets('a recalled pack and an unscanned handset can go back', (
    tester,
  ) async {
    final repository = await _pumpOrder(
      tester,
      mode: 'serial_batch',
      units: const [
        StockUnit(
          id: 201,
          variantId: 11,
          code: 'PACK-R',
          batchId: 5,
          batchCode: 'LOT-R',
          batchStatus: 'quarantined',
          batchIsSellable: false,
        ),
        StockUnit(
          id: 202,
          variantId: 11,
          code: '#-PO300L1-3f9a2c1b-1',
          isIdentified: false,
        ),
      ],
    );

    await _openReturn(tester);
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();

    // The recall is marked, and the placeholder reads as what it is rather
    // than as a generated code nobody printed on a box.
    expect(find.text('PACK-R'), findsOneWidget);
    expect(find.text('دفعة LOT-R'), findsOneWidget);
    expect(find.text('محجورة'), findsOneWidget);
    expect(find.text('بانتظار المعرّف'), findsOneWidget);
    expect(find.textContaining('#-PO300'), findsNothing);

    await tester.tap(find.text('PACK-R'));
    await tester.tap(find.text('بانتظار المعرّف'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'تأكيد'));
    await tester.pumpAndSettle();

    final sent = repository.returned!.toJson()['lines']! as List<Object?>;
    expect((sent.single! as Map)['units'], [201, 202]);
  });

  testWidgets('a lot line can name the recalled lot it sends back', (
    tester,
  ) async {
    final repository = await _pumpOrder(tester, mode: 'batch');

    await _openReturn(tester);
    expect(find.textContaining('تُحدَّد الدفعات بعد التأكيد'), findsOneWidget);
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();

    expect(find.text('حدّد الدفعات المُرجَعة للمورد'), findsOneWidget);
    expect(repository.requestedLotWarehouses, [7]);
    // Only lots holding goods where the delivery landed; the recall first.
    expect(find.text('LOT-EMPTY'), findsNothing);
    final recalled = tester.getTopLeft(find.text('LOT-R'));
    final good = tester.getTopLeft(find.text('LOT-G'));
    expect(recalled.dy, lessThan(good.dy));
    expect(find.text('محجورة'), findsOneWidget);
    expect(
      find.text('تلقائي: الأقرب انتهاءً من الدفعات الصالحة'),
      findsOneWidget,
    );

    await tester.tap(find.text('LOT-R'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'تأكيد'));
    await tester.pumpAndSettle();

    final sent = repository.returned!.toJson()['lines']! as List<Object?>;
    expect(sent, [
      {
        'line': 1,
        'quantity': '1.000',
        'batches': [5],
      },
    ]);
  });

  testWidgets('a lot line that names nothing goes back earliest-expiry first', (
    tester,
  ) async {
    final repository = await _pumpOrder(tester, mode: 'batch');

    await _openReturn(tester);
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'تأكيد'));
    await tester.pumpAndSettle();

    final sent = repository.returned!.toJson()['lines']! as List<Object?>;
    expect(sent, [
      {'line': 1, 'quantity': '1.000'},
    ]);
  });
}

Future<void> _openReturn(WidgetTester tester) async {
  await tester.tap(find.text('إجراءات أخرى'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('إرجاع'));
  await tester.pumpAndSettle();
}

Future<_FakePurchaseRepository> _pumpOrder(
  WidgetTester tester, {
  String mode = 'serial',
  List<StockUnit> units = const [
    StockUnit(id: 101, variantId: 11, code: 'SN-1'),
    StockUnit(id: 102, variantId: 11, code: 'SN-2'),
  ],
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final order = _receivedPhoneOrder(mode: mode);
  final repository = _FakePurchaseRepository(order, units: units);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: PurchaseOrderDetailsScreen(
        purchaseRepository: repository,
        printingRepository: PrintingRepository(PosApiService()),
        shopSettingsRepository: ShopSettingsRepository(PosApiService()),
        initialOrder: order,
        capabilities: AuthorizationCapabilities.forUser(managerUser),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository(this.order, {required this.units})
    : super(PosApiService());

  final PurchaseOrder order;
  final List<StockUnit> units;
  final List<int?> requestedWarehouses = [];
  final List<int?> requestedLotWarehouses = [];
  PurchaseAdjustmentDraft? returned;
  PurchaseAdjustmentDraft? exchanged;

  @override
  Future<Result<PurchaseOrder>> loadPurchaseOrder(int purchaseOrderId) async {
    return Ok(order);
  }

  @override
  Future<Result<StockUnitPage>> loadReturnableUnits({
    required int variantId,
    int? warehouseId,
    String code = '',
  }) async {
    requestedWarehouses.add(warehouseId);
    return Ok(StockUnitPage(units: units));
  }

  /// A good lot, a recalled one (both with goods in warehouse 7), and one
  /// whose goods are all elsewhere.
  @override
  Future<Result<StockBatchPage>> loadReturnableLots({
    required int variantId,
    int? warehouseId,
  }) async {
    requestedLotWarehouses.add(warehouseId);
    return Ok(
      StockBatchPage(
        batches: [
          _lot(4, 'LOT-G', DateTime(2027, 3, 1), here: 6),
          _lot(
            5,
            'LOT-R',
            DateTime(2027, 9, 1),
            here: 4,
            status: StockBatchStatus.quarantined,
          ),
          _lot(6, 'LOT-EMPTY', DateTime(2027, 1, 1), here: 0),
        ],
      ),
    );
  }

  @override
  Future<Result<PurchaseOrder>> returnItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
    String? idempotencyKey,
  }) async {
    returned = draft;
    return Ok(order);
  }

  @override
  Future<Result<PurchaseOrder>> exchangeItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
    String? idempotencyKey,
  }) async {
    exchanged = draft;
    return Ok(order);
  }
}

/// Two handsets and a box of chargers, received into warehouse 7.
PurchaseOrder _receivedPhoneOrder({required String mode}) {
  return PurchaseOrder.fromJson({
    'id': 300,
    'order_number': 'P20261004000300',
    'supplier': 14,
    'supplier_name': 'مورد الهواتف',
    'warehouse': 7,
    'status': 'received',
    'lines': [
      {
        'id': 1,
        'product': 10,
        'variant': 11,
        'product_name': 'هاتف',
        'tracking_mode': mode,
        'quantity': 2,
        'received_quantity': 2,
        'open_quantity': 0,
        'adjustable_quantity': 2,
        'unit_cost': '900.00',
        'line_total': '1800.00',
      },
      {
        'id': 2,
        'product': 20,
        'variant': 21,
        'product_name': 'شاحن',
        'quantity': 5,
        'received_quantity': 5,
        'open_quantity': 0,
        'adjustable_quantity': 5,
        'unit_cost': '10.00',
        'line_total': '50.00',
      },
    ],
    'subtotal': '1850.00',
    'total': '1850.00',
    'paid_total': '1850.00',
    'balance_due': '0.00',
    'payment_status': 'paid',
    'can_return': true,
    'can_refund': true,
    'can_exchange': true,
    'submitted_at': '2026-10-01T10:00:00Z',
    'received_at': '2026-10-02T10:00:00Z',
    'created_at': '2026-10-01T09:00:00Z',
  });
}

StockBatch _lot(
  int id,
  String code,
  DateTime expiry, {
  required double here,
  String status = StockBatchStatus.active,
}) {
  final sellable = status == StockBatchStatus.active;
  return StockBatch(
    id: id,
    variantId: 11,
    code: code,
    displayCode: code,
    expiryDate: expiry,
    status: status,
    isLocked: !sellable,
    isSellable: sellable,
    onHand: here,
    balances: [
      StockBatchBalance(
        id: id * 10,
        batchId: id,
        warehouseId: 7,
        remainingQuantity: here,
        isSellable: sellable,
      ),
    ],
  );
}
