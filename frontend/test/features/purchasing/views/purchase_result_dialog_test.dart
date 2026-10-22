import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_order_documents.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_result/purchase_result_dialog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/tracking/tracking_features.dart';

/// The purchase order's result: sent, then received in the same dialog —
/// at once for goods counted, through the receiving form for goods named.
void main() {
  Finder key(String value) => find.byKey(ValueKey(value));

  testWidgets('counted goods are sent, then received in one tap', (
    tester,
  ) async {
    final purchases = _Purchases(
      lines: [_line(1, 'أرز ٥ كغ', TrackingMode.quantity, 4)],
    );
    final host = await _open(tester, purchases);

    expect(key('purchase_result_recorded'), findsOneWidget);
    expect(find.text('تم إرسال أمر الشراء'), findsOneWidget);
    expect(find.textContaining('مخازن الأمل'), findsOneWidget);
    expect(key('purchase_result_total'), findsOneWidget);
    expect(key('purchase_result_awaiting'), findsOneWidget);
    expect(find.text('استلام لاحقًا'), findsOneWidget);

    await tester.tap(key('purchase_result_receive'));
    await tester.pumpAndSettle();

    final receipt = purchases.receipts.single;
    expect(receipt.draft.lines.single.quantityReceived, 4);
    expect(receipt.draft.lines.single.capture, isNull);
    expect(key('purchase_result_received'), findsOneWidget);
    expect(find.text('تم استلام البضاعة'), findsOneWidget);
    expect(key('purchase_result_received_lines'), findsOneWidget);
    expect(key('purchase_result_labels'), findsNothing);

    await tester.tap(key('purchase_result_done'));
    await tester.pumpAndSettle();
    expect(host.exit, isA<PurchaseResultDone>());
  });

  testWidgets('handsets turn the result into the receiving form', (
    tester,
  ) async {
    final purchases = _Purchases(
      lines: [_line(1, 'آيفون', TrackingMode.serial, 2)],
    );
    await _open(tester, purchases);

    expect(key('purchase_result_tracked_lines'), findsOneWidget);
    expect(find.text('تُمسح الأرقام التسلسلية عند الاستلام.'), findsOneWidget);
    // Nothing to adjust before scanning: the form is where the receipt goes.
    expect(key('purchase_result_receive_adjust'), findsNothing);

    await tester.tap(key('purchase_result_receive'));
    await tester.pumpAndSettle();
    expect(key('purchase_result_receive_form'), findsOneWidget);
    expect(key('purchase-receive-capture-1'), findsOneWidget);

    // Unscanned handsets are caught in the form, not by the server.
    await tester.tap(key('purchase_result_confirm_receive'));
    await tester.pumpAndSettle();
    expect(key('purchase-receive-capture-error'), findsOneWidget);
    expect(purchases.receipts, isEmpty);

    // Escape leaves the form, not the result.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(key('purchase_result_receive_form'), findsNothing);
    expect(key('purchase_result_recorded'), findsOneWidget);
  });

  testWidgets('scanned in the form, the handsets go in with their numbers', (
    tester,
  ) async {
    final purchases = _Purchases(
      lines: [_line(1, 'آيفون', TrackingMode.serial, 2)],
    );
    await _open(tester, purchases, documents: true);
    await tester.tap(key('purchase_result_receive'));
    await tester.pumpAndSettle();

    await tester.tap(key('purchase-receive-capture-1'));
    await tester.pumpAndSettle();
    for (final code in ['SN-1', 'SN-2']) {
      await tester.enterText(key('unit-capture-input'), code);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }
    await tester.tap(key('unit-capture-confirm'));
    await tester.pumpAndSettle();

    await tester.tap(key('purchase_result_confirm_receive'));
    await tester.pumpAndSettle();

    final units = purchases.receipts.single.draft.lines.single.capture!.units;
    expect(units.map((unit) => unit.code), ['SN-1', 'SN-2']);
    expect(key('purchase_result_received'), findsOneWidget);
    // Handsets are labelled while the boxes are still open.
    expect(key('purchase_result_labels'), findsOneWidget);
    expect(key('purchase_result_action_print'), findsOneWidget);
    expect(key('purchase_result_action_share'), findsOneWidget);
  });

  testWidgets('a refused receipt keeps the order and retries the same key', (
    tester,
  ) async {
    final purchases = _Purchases(
      lines: [_line(1, 'أرز', TrackingMode.quantity, 4)],
      receiveFailures: 1,
    );
    await _open(tester, purchases);

    await tester.tap(key('purchase_result_receive'));
    await tester.pumpAndSettle();
    expect(key('purchase_result_receive_error'), findsOneWidget);
    expect(key('result_mark_attention'), findsOneWidget);
    expect(
      find.textContaining('تأكّد من اتصال الجهاز بالشبكة'),
      findsOneWidget,
    );

    await tester.tap(key('purchase_result_receive'));
    await tester.pumpAndSettle();
    expect(key('purchase_result_received'), findsOneWidget);
    expect(purchases.receipts, hasLength(2));
    expect(purchases.receipts[0].key, purchases.receipts[1].key);
  });

  testWidgets('different counts are typed in the form for counted goods', (
    tester,
  ) async {
    final purchases = _Purchases(
      lines: [_line(1, 'أرز', TrackingMode.quantity, 10)],
    );
    await _open(tester, purchases);

    await tester.tap(key('purchase_result_receive_adjust'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'مستلم سليم'), '8');
    await tester.tap(key('purchase_result_confirm_receive'));
    await tester.pumpAndSettle();

    expect(purchases.receipts.single.draft.lines.single.quantityReceived, 8);
    expect(key('purchase_result_still_open'), findsOneWidget);
  });

  testWidgets('a taken supplier invoice number leads back to the settings', (
    tester,
  ) async {
    final purchases = _Purchases(
      lines: [_line(1, 'أرز', TrackingMode.quantity, 1)],
      submitFailures: [
        const PosApiException(
          message: 'bad',
          statusCode: 400,
          responseBody: '{"supplier_invoice_number": ["duplicate"]}',
        ),
      ],
    );
    final host = await _open(tester, purchases);

    expect(key('purchase_result_failure'), findsOneWidget);
    expect(find.text('رقم فاتورة المورد مكرر'), findsWidgets);
    expect(key('purchase_result_retry'), findsNothing);

    await tester.tap(key('purchase_result_edit_invoice'));
    await tester.pumpAndSettle();
    expect(host.exit, isA<PurchaseResultEditInvoice>());
  });

  testWidgets('no answer says so, and the retry records it once', (
    tester,
  ) async {
    final purchases = _Purchases(
      lines: [_line(1, 'أرز', TrackingMode.quantity, 1)],
      submitFailures: [
        const PosApiException(
          message: 'timeout',
          statusCode: 0,
          responseBody: '',
        ),
      ],
    );
    await _open(tester, purchases);

    expect(find.text('لم يصل ردّ الخادم'), findsOneWidget);
    await tester.tap(key('purchase_result_retry'));
    await tester.pumpAndSettle();

    expect(key('purchase_result_recorded'), findsOneWidget);
    expect(purchases.submitKeys, hasLength(2));
    expect(purchases.submitKeys.toSet(), hasLength(1));
  });

  testWidgets('a doubted cost is confirmed by a tap, then sent', (
    tester,
  ) async {
    final purchases = _Purchases(
      lines: [_line(1, 'خبز', TrackingMode.quantity, 1)],
      submitFailures: [
        PosApiException(
          message: 'cost',
          statusCode: 400,
          responseBody: jsonEncode({
            'cost_warnings': [
              {
                'kind': 'cost_above_price',
                'blocking': false,
                'product_name': 'خبز',
                'message': 'التكلفة 130 والسعر 1',
              },
            ],
          }),
        ),
      ],
    );
    await _open(tester, purchases);

    expect(key('purchase_result_cost_warnings'), findsOneWidget);
    expect(find.text('التكلفة 130 والسعر 1'), findsOneWidget);
    await tester.tap(key('purchase_result_cost_confirm'));
    await tester.pumpAndSettle();

    expect(purchases.acknowledged, [false, true]);
    expect(key('purchase_result_recorded'), findsOneWidget);
  });

  testWidgets('a buyer who may not receive is not offered it', (tester) async {
    final purchases = _Purchases(
      lines: [_line(1, 'أرز', TrackingMode.quantity, 1)],
    );
    final host = await _open(tester, purchases, canReceive: false);

    expect(key('purchase_result_receive'), findsNothing);
    expect(find.text('أمر شراء جديد'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(host.exit, isA<PurchaseResultDone>());
  });

  testWidgets('saving a reopened draft says it is still a draft', (
    tester,
  ) async {
    final purchases = _Purchases(
      lines: [_line(1, 'أرز', TrackingMode.quantity, 1)],
      status: 'draft',
    );
    await _open(tester, purchases, mode: PurchaseResultMode.save);

    expect(find.text('تم حفظ التعديلات'), findsOneWidget);
    expect(key('purchase_result_draft_note'), findsOneWidget);
    expect(key('purchase_result_receive'), findsNothing);
    expect(find.text('تم'), findsOneWidget);
  });
}

class _Host {
  PurchaseResultExit? exit;
}

Future<_Host> _open(
  WidgetTester tester,
  _Purchases purchases, {
  PurchaseResultMode mode = PurchaseResultMode.submit,
  bool canReceive = true,
  bool documents = false,
}) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final viewModel = PurchaseViewModel(_Catalog(), purchases);
  addTearDown(viewModel.dispose);
  if (mode == PurchaseResultMode.save) {
    // The fake catalog resolves none of the order's lines; the one below is
    // the edit being saved.
    await viewModel.loadOrderForEditing(purchases.order('draft'));
  } else {
    viewModel.selectSupplier(_supplier);
  }
  await viewModel.addVariant(
    const ProductVariant(
      id: 1,
      productId: 1,
      sku: 'SKU-1',
      unitPrice: 20,
      productName: 'صنف',
    ),
    quantity: 1,
    unitCost: 10,
  );

  final host = _Host();
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
      builder: (context, child) => TrackingFeaturesScope(
        features: const TrackingFeatures(serial: true, batch: true),
        child: child ?? const SizedBox.shrink(),
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                host.exit = await showPurchaseResultDialog(
                  context: context,
                  viewModel: viewModel,
                  mode: mode,
                  canReceive: canReceive,
                  documents: documents
                      ? PurchaseOrderDocuments(
                          printingRepository: PrintingRepository(
                            PosApiService(),
                          ),
                          shopSettingsRepository: ShopSettingsRepository(
                            PosApiService(),
                          ),
                        )
                      : null,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  // Past the discount preview's debounce, so no timer outlives the test.
  await tester.pump(const Duration(seconds: 1));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return host;
}

const _supplier = SupplierContact(
  id: 7,
  name: 'مخازن الأمل',
  contactName: '',
  phone: '',
  email: '',
  address: '',
  notes: '',
  isActive: true,
);

PurchaseOrderLine _line(
  int id,
  String name,
  TrackingMode mode,
  double quantity,
) {
  return PurchaseOrderLine(
    id: id,
    productId: id,
    variantId: id,
    quantity: quantity,
    adjustedQuantity: 0,
    adjustableQuantity: 0,
    receivedQuantity: 0,
    damagedQuantity: 0,
    rejectedQuantity: 0,
    openQuantity: quantity,
    hasReceivingTotals: false,
    unitCost: 10,
    total: quantity * 10,
    productName: name,
    trackingMode: mode,
  );
}

class _Receipt {
  const _Receipt(this.draft, this.key);

  final PurchaseReceiveDraft draft;
  final String? key;
}

class _Purchases extends PurchaseRepository {
  _Purchases({
    required this.lines,
    this.status = 'submitted',
    List<Object> submitFailures = const [],
    this.receiveFailures = 0,
  }) : _submitFailures = List.of(submitFailures),
       super(PosApiService());

  final List<PurchaseOrderLine> lines;
  final String status;
  final List<Object> _submitFailures;
  int receiveFailures;
  final receipts = <_Receipt>[];
  final submitKeys = <String?>[];
  final acknowledged = <bool>[];

  PurchaseOrder order(String status, {List<PurchaseOrderLine>? lines}) {
    final orderLines = lines ?? this.lines;
    return PurchaseOrder(
      id: 31,
      orderNumber: 'PO-31',
      status: status,
      supplierId: _supplier.id,
      supplierName: _supplier.name,
      lineCount: orderLines.length,
      total: 40,
      subtotal: 40,
      lines: orderLines,
      adjustments: const [],
      receipts: const [],
      canReturn: false,
      canRefund: false,
      canExchange: false,
    );
  }

  @override
  Future<Result<PurchaseDiscountPreview>> previewDiscounts(
    PurchaseDiscountPreviewDraft draft,
  ) async => Error(Exception('offline'));

  @override
  Future<Result<double?>> loadLastProductCost(
    int productId, {
    int? variantId,
  }) async => const Ok(10);

  @override
  Future<Result<PurchaseSubmission>> submitDraft(
    List<PurchaseDraftLine> lines, {
    required int supplierId,
    int? warehouseId,
    String supplierInvoiceNumber = '',
    DateTime? supplierInvoiceDate,
    List<PurchaseLandedCostEntry> landedCostEntries = const [],
    LandedCostAllocationMethod landedCostAllocationMethod =
        LandedCostAllocationMethod.byLineValue,
    String discountCode = '',
    double extraDiscountAmount = 0,
    String? idempotencyKey,
    String currencyCode = '',
    double? exchangeRate,
    bool acknowledgeCostWarnings = false,
    void Function()? onCreated,
  }) async {
    submitKeys.add(idempotencyKey);
    acknowledged.add(acknowledgeCostWarnings);
    if (_submitFailures.isNotEmpty) {
      return Error(_submitFailures.removeAt(0) as Exception);
    }
    onCreated?.call();
    return Ok(order(status).toSubmission());
  }

  @override
  Future<Result<PurchaseOrder>> updateDraftOrder(
    int purchaseOrderId,
    List<PurchaseDraftLine> lines, {
    required int supplierId,
    String supplierInvoiceNumber = '',
    DateTime? supplierInvoiceDate,
    List<PurchaseLandedCostEntry> landedCostEntries = const [],
    LandedCostAllocationMethod landedCostAllocationMethod =
        LandedCostAllocationMethod.byLineValue,
    String discountCode = '',
    double extraDiscountAmount = 0,
    bool acknowledgeCostWarnings = false,
  }) async => Ok(order(status));

  @override
  Future<Result<PurchaseOrder>> receiveLines({
    required int purchaseOrderId,
    required PurchaseReceiveDraft draft,
    String? idempotencyKey,
  }) async {
    receipts.add(_Receipt(draft, idempotencyKey));
    if (receiveFailures > 0) {
      receiveFailures--;
      return const Error(
        PosApiException(message: 'timeout', statusCode: 0, responseBody: ''),
      );
    }
    final received = {
      for (final line in draft.lines) line.purchaseLineId: line,
    };
    final after = [
      for (final line in lines)
        PurchaseOrderLine(
          id: line.id,
          productId: line.productId,
          variantId: line.variantId,
          quantity: line.quantity,
          adjustedQuantity: 0,
          adjustableQuantity: 0,
          receivedQuantity: received[line.id]?.quantityReceived ?? 0,
          damagedQuantity: 0,
          rejectedQuantity: 0,
          openQuantity:
              line.quantity - (received[line.id]?.quantityReceived ?? 0),
          hasReceivingTotals: true,
          unitCost: line.unitCost,
          total: line.total,
          productName: line.productName,
          trackingMode: line.trackingMode,
        ),
    ];
    final open = after.any((line) => line.openQuantity > 0);
    return Ok(order(open ? 'partial' : 'received', lines: after));
  }
}

class _Catalog extends CatalogRepository {
  _Catalog() : super(PosApiService());

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => const Ok(ProductVariantPage(variants: [], hasMore: false));

  @override
  Future<Result<Product>> loadProduct(int id) async =>
      Error(Exception('product $id not found'));
}
