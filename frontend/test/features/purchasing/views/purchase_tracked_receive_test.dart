import 'package:flutter/material.dart';
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
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_draft_pane.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_order_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/tracking/tracking_features.dart';
import 'package:pointy_frontend/src/shared/tracking/unit_intake_permissions.dart';

/// Receiving tracked goods: lots carry their own dates, the boxes fit a phone,
/// and a capture that no longer matches the quantity is caught before it posts.
void main() {
  testWidgets('a lot line asks no date of its own and sends the first lot\'s', (
    tester,
  ) async {
    final draft = await _receive(
      tester,
      lines: [_line(1, 'حليب أطفال', TrackingMode.batch, 24, expiry: true)],
      script: (tester) async {
        // The old line-level date field is gone; the hint points at the lots.
        expect(find.text('تاريخ الانتهاء'), findsNothing);
        expect(
          find.text('تُسجَّل الصلاحية لكل دفعة عند إدخال الدفعات.'),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const ValueKey('purchase-receive-capture-1')),
        );
        await tester.pumpAndSettle();
        final fields = find.byType(TextFormField);
        await tester.enterText(fields.at(0), 'L-A');
        await tester.pump();
        await tester.enterText(fields.at(1), '15');
        await tester.pump();
        await tester.tap(find.widgetWithText(OutlinedButton, '+12ش').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('إضافة دفعة أخرى'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField).at(2), 'L-B');
        await tester.pump();
        await tester.tap(find.widgetWithText(OutlinedButton, '+6ش').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('batch-capture-confirm')));
        await tester.pumpAndSettle();

        expect(find.textContaining('أقرب صلاحية'), findsOneWidget);
        expect(find.text('تعديل الدفعات'), findsOneWidget);
      },
    );

    final line = draft!.lines.single;
    final lots = line.capture!.batches;
    expect(lots, hasLength(2));
    final earliest = lots
        .map((lot) => lot.expiryDate!)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    expect(line.expiryDate, earliest);
  });

  testWidgets('on a phone the three boxes stop squeezing their labels', (
    tester,
  ) async {
    await _receive(
      tester,
      size: const Size(390, 844),
      lines: [_line(1, 'شاحن', TrackingMode.quantity, 5)],
      confirm: false,
      script: (tester) async {
        final received = tester.getSize(
          find.widgetWithText(TextField, 'مستلم سليم'),
        );
        final damaged = tester.getSize(
          find.widgetWithText(TextField, 'تالف عند الوصول'),
        );
        // What arrived gets the whole row; the other two share the next.
        expect(received.width, greaterThan(damaged.width * 1.8));
        expect(tester.takeException(), isNull);
      },
    );
  });

  testWidgets('scanning three handsets and then receiving two is caught', (
    tester,
  ) async {
    final draft = await _receive(
      tester,
      lines: [_line(1, 'آيفون', TrackingMode.serial, 3)],
      script: (tester) async {
        await tester.tap(
          find.byKey(const ValueKey('purchase-receive-capture-1')),
        );
        await tester.pumpAndSettle();
        for (final code in ['SN-1', 'SN-2', 'SN-3']) {
          await tester.enterText(
            find.byKey(const ValueKey('unit-capture-input')),
            code,
          );
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const ValueKey('unit-capture-confirm')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextField, 'مستلم سليم'),
          '2',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('تأكيد'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('purchase-receive-capture-error')),
          findsOneWidget,
        );
        // Put right, it goes.
        await tester.enterText(
          find.widgetWithText(TextField, 'مستلم سليم'),
          '3',
        );
        await tester.pumpAndSettle();
      },
    );
    expect(draft!.lines.single.capture!.units, hasLength(3));
  });

  testWidgets('a buyer who may reprice prices each handset as it is scanned', (
    tester,
  ) async {
    await _receive(
      tester,
      lines: [_line(1, 'آيفون مستعمل', TrackingMode.serial, 1)],
      permissions: const UnitIntakePermissions(canSetPrice: true),
      confirm: false,
      script: (tester) async {
        await tester.tap(
          find.byKey(const ValueKey('purchase-receive-capture-1')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('unit-capture-input')),
          'SN-1',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(find.text('السعر'), findsOneWidget);
      },
    );
  });

  group('the order line says what receiving will ask', () {
    testWidgets('paint is named in lots, never dated', (tester) async {
      await _pumpDraft(tester, [
        _variant(1, 'دهان', TrackingMode.batch),
        _variant(2, 'حليب', TrackingMode.batch, expiryRequired: true),
        _variant(
          3,
          'قلم إنسولين',
          TrackingMode.serialBatch,
          expiryRequired: true,
        ),
      ]);

      expect(find.text('تُسجَّل أرقام الدفعات عند الاستلام.'), findsOneWidget);
      expect(
        find.text('تُسجَّل الدفعات وتواريخ صلاحيتها عند الاستلام.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'تُسجَّل الدفعة وصلاحيتها وتُمسح الأرقام التسلسلية عند الاستلام.',
        ),
        findsOneWidget,
      );
      // No line asks for a date before the goods exist.
      expect(find.text('تاريخ الانتهاء'), findsNothing);
    });
  });
}

PurchaseOrderLine _line(
  int id,
  String name,
  TrackingMode mode,
  double quantity, {
  bool expiry = false,
}) {
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
    tracksExpiry: expiry,
  );
}

Future<PurchaseReceiveDraft?> _receive(
  WidgetTester tester, {
  required List<PurchaseOrderLine> lines,
  required Future<void> Function(WidgetTester tester) script,
  Size size = const Size(1200, 1400),
  UnitIntakePermissions permissions = UnitIntakePermissions.none,
  bool confirm = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final order = PurchaseOrder(
    id: 9,
    orderNumber: 'PO-9',
    status: 'submitted',
    lineCount: lines.length,
    total: 0,
    subtotal: 0,
    lines: lines,
    adjustments: const [],
    receipts: const [],
    canReturn: false,
    canRefund: false,
    canExchange: false,
  );
  PurchaseReceiveDraft? result;
  await tester.pumpWidget(
    _app(
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                result = await showPurchaseReceiveCaptureDialog(
                  context,
                  order: order,
                  permissions: permissions,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await script(tester);
  if (confirm) {
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();
  }
  return result;
}

ProductVariant _variant(
  int id,
  String name,
  TrackingMode mode, {
  bool expiryRequired = false,
}) {
  return ProductVariant(
    id: id,
    productId: id,
    sku: 'SKU-$id',
    unitPrice: 10,
    productName: name,
    trackingMode: mode,
    tracksExpiry: mode.tracksLots,
    expiryRequired: expiryRequired,
  );
}

Future<void> _pumpDraft(
  WidgetTester tester,
  List<ProductVariant> variants,
) async {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final viewModel = PurchaseViewModel(_Catalog(), _Purchases());
  addTearDown(viewModel.dispose);
  for (final variant in variants) {
    await viewModel.addVariant(variant, quantity: 2, unitCost: 10);
  }
  await tester.pumpWidget(
    _app(
      Scaffold(
        body: PurchaseDraftPane(
          viewModel: viewModel,
          contactRepository: _Contacts(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Widget _app(Widget home) => MaterialApp(
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
  home: home,
);

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

class _Purchases extends PurchaseRepository {
  _Purchases() : super(PosApiService());

  @override
  Future<Result<double?>> loadLastProductCost(
    int productId, {
    int? variantId,
  }) async => const Ok(10);
}

class _Contacts extends ContactRepository {
  _Contacts() : super(PosApiService());

  @override
  Future<Result<SupplierPage>> loadSuppliers({
    required ContactQuery query,
    int page = 1,
  }) async => const Ok(SupplierPage(suppliers: [], hasMore: false));
}
