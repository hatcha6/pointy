// Dev-only preview harness for the dialog a purchase order ends in.
//
// Runs the real dialog over a fake repository — no backend, no auth — so the
// whole sweep can be felt: sending, the result, receiving at once or through
// the receiving form (scan sheets included), and the received result.
//
//   make frontend-purchase-result-preview
//
// `?scenario=` picks what the fake server does:
//   counted (default) | tracked | partial | invoice-taken | cost | offline
//   | receive-fails | saved
// Add `&theme=dark` for dark mode. The dialog opens on load; close it and
// press the button to run it again. Not part of the shipping app. Safe to
// delete.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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
import 'package:pointy_frontend/src/data/services/order_document_service.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_order_documents.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_result/purchase_result_dialog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/data/models/unit_attribute.dart';
import 'package:pointy_frontend/src/shared/tracking/tracking_features.dart';
import 'package:pointy_frontend/src/shared/tracking/unit_attribute_catalog.dart';
import 'package:pointy_frontend/src/shared/tracking/unit_intake_permissions.dart';

void main() => runApp(const _PreviewApp());

bool get _dark => Uri.base.queryParameters['theme'] == 'dark';

String get _scenario => Uri.base.queryParameters['scenario'] ?? 'counted';

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: _dark ? PointyTheme.dark() : PointyTheme.light(),
      builder: (context, child) => TrackingFeaturesScope(
        features: const TrackingFeatures(serial: true, batch: true),
        // A phone's checklist, so the scan sheet offers each handset's
        // details as it does in a shop that defined one.
        child: UnitAttributeCatalogScope(
          catalog: _checklists,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      home: const _Host(),
    );
  }
}

class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String _lastExit = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final saving = _scenario == 'saved';
    final purchases = _FakePurchases(_scenario);
    final viewModel = PurchaseViewModel(_FakeCatalog(), purchases);
    if (saving) {
      await viewModel.loadOrderForEditing(purchases.order('submitted'));
    } else {
      viewModel.selectSupplier(_supplier);
    }
    for (final variant in _variants) {
      await viewModel.addVariant(variant, quantity: 2, unitCost: 10);
    }
    if (!mounted) return;
    final exit = await showPurchaseResultDialog(
      context: context,
      viewModel: viewModel,
      mode: saving ? PurchaseResultMode.save : PurchaseResultMode.submit,
      documents: _FakeDocuments(),
      permissions: const UnitIntakePermissions(canSetPrice: true),
    );
    viewModel.dispose();
    if (mounted) setState(() => _lastExit = exit.runtimeType.toString());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pointyColors.page,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: _run,
              icon: const Icon(Icons.send_rounded),
              label: const Text('إرسال أمر الشراء'),
            ),
            const SizedBox(height: 12),
            Text(
              '$_scenario  →  $_lastExit',
              textDirection: TextDirection.ltr,
              style: TextStyle(color: context.pointyColors.mutedInk),
            ),
          ],
        ),
      ),
    );
  }
}

final _checklists = UnitAttributeCatalog(
  (assetTypeId) async => const Ok([
    UnitAttributeDefinition(
      key: 'battery',
      label: 'صحة البطارية',
      dataType: UnitAttributeType.number,
      suffix: '%',
      isRequired: true,
    ),
    UnitAttributeDefinition(
      key: 'condition',
      label: 'الحالة',
      dataType: UnitAttributeType.choice,
      choices: [
        UnitAttributeChoice(value: 'new', label: 'جديد'),
        UnitAttributeChoice(value: 'clean', label: 'مستعمل نظيف'),
        UnitAttributeChoice(value: 'scratched', label: 'به خدوش'),
      ],
    ),
    UnitAttributeDefinition(key: 'accessories', label: 'الملحقات'),
  ]),
);

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

const _variants = [
  ProductVariant(
    id: 1,
    productId: 1,
    sku: 'RICE-5',
    unitPrice: 25,
    productName: 'أرز ٥ كغ',
  ),
];

PurchaseOrderLine _line(
  int id,
  String name,
  TrackingMode mode,
  double quantity, {
  bool expiry = false,
  double received = 0,
  int? assetTypeId,
}) {
  return PurchaseOrderLine(
    id: id,
    productId: id,
    variantId: id,
    quantity: quantity,
    adjustedQuantity: 0,
    adjustableQuantity: 0,
    receivedQuantity: received,
    damagedQuantity: 0,
    rejectedQuantity: 0,
    openQuantity: quantity - received,
    hasReceivingTotals: received > 0,
    unitCost: 18,
    total: quantity * 18,
    productName: name,
    trackingMode: mode,
    tracksExpiry: expiry,
    assetTypeId: assetTypeId,
    sellingPrice: 25,
    unitLabel: mode == TrackingMode.quantity ? 'كرتونة' : '',
  );
}

List<PurchaseOrderLine> _linesFor(String scenario) => switch (scenario) {
  'tracked' => [
    _line(1, 'آيفون 15 برو', TrackingMode.serial, 2, assetTypeId: 1),
    _line(2, 'حليب أطفال', TrackingMode.batch, 12, expiry: true),
    _line(3, 'أرز ٥ كغ', TrackingMode.quantity, 5),
  ],
  _ => [
    _line(1, 'أرز ٥ كغ', TrackingMode.quantity, 10),
    _line(2, 'سكر ١ كغ', TrackingMode.quantity, 24),
    _line(3, 'زيت ذرة', TrackingMode.quantity, 6),
  ],
};

class _FakePurchases extends PurchaseRepository {
  _FakePurchases(this.scenario)
    : lines = _linesFor(scenario),
      super(PosApiService());

  final String scenario;
  List<PurchaseOrderLine> lines;
  var _submits = 0;
  var _receipts = 0;

  PurchaseOrder order(String status) => PurchaseOrder(
    id: 31,
    orderNumber: 'P20261017000031',
    status: status,
    supplierId: _supplier.id,
    supplierName: _supplier.name,
    lineCount: lines.length,
    total: lines.fold(0.0, (sum, line) => sum + line.total),
    subtotal: lines.fold(0.0, (sum, line) => sum + line.total),
    lines: lines,
    adjustments: const [],
    receipts: const [],
    canReturn: false,
    canRefund: false,
    canExchange: false,
  );

  @override
  Future<Result<PurchaseDiscountPreview>> previewDiscounts(
    PurchaseDiscountPreviewDraft draft,
  ) async => Error(Exception('preview'));

  @override
  Future<Result<double?>> loadLastProductCost(
    int productId, {
    int? variantId,
  }) async => const Ok(18);

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
    _submits++;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final first = _submits == 1;
    if (first && scenario == 'invoice-taken') {
      return const Error(
        PosApiException(
          message: 'duplicate',
          statusCode: 400,
          responseBody: '{"supplier_invoice_number": ["duplicate"]}',
        ),
      );
    }
    if (first && scenario == 'offline') {
      return const Error(
        PosApiException(message: 'timeout', statusCode: 0, responseBody: ''),
      );
    }
    if (scenario == 'cost' && !acknowledgeCostWarnings) {
      return Error(
        PosApiException(
          message: 'cost',
          statusCode: 400,
          responseBody: jsonEncode({
            'cost_warnings': [
              {
                'kind': 'cost_above_price',
                'blocking': false,
                'product_name': 'أرز ٥ كغ',
                'message': 'التكلفة 180.00 للوحدة، وسعر البيع 25.00.',
              },
            ],
          }),
        ),
      );
    }
    onCreated?.call();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (scenario == 'partial') {
      this.lines = [
        _line(1, 'أرز ٥ كغ', TrackingMode.quantity, 10, received: 4),
        _line(2, 'سكر ١ كغ', TrackingMode.quantity, 24),
      ];
      return Ok(order('partially_received').toSubmission());
    }
    return Ok(order('submitted').toSubmission());
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
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    return Ok(order('submitted'));
  }

  @override
  Future<Result<PurchaseOrder>> receiveLines({
    required int purchaseOrderId,
    required PurchaseReceiveDraft draft,
    String? idempotencyKey,
  }) async {
    _receipts++;
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    if (scenario == 'receive-fails' && _receipts == 1) {
      return const Error(
        PosApiException(message: 'timeout', statusCode: 0, responseBody: ''),
      );
    }
    final received = {
      for (final line in draft.lines) line.purchaseLineId: line,
    };
    lines = [
      for (final line in lines)
        _line(
          line.id,
          line.productName ?? '',
          line.trackingMode,
          line.quantity,
          expiry: line.tracksExpiry,
          assetTypeId: line.assetTypeId,
          received:
              line.receivedQuantity +
              (received[line.id]?.quantityReceived ?? 0),
        ),
    ];
    final open = lines.any((line) => line.openQuantity > 0);
    return Ok(order(open ? 'partially_received' : 'received'));
  }

  @override
  Future<Result<PurchaseOrder>> loadPurchaseOrder(int id) async =>
      Ok(order('submitted'));
}

class _FakeCatalog extends CatalogRepository {
  _FakeCatalog() : super(PosApiService());

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => const Ok(ProductVariantPage(variants: [], hasMore: false));

  @override
  Future<Result<Product>> loadProduct(int id) async =>
      Error(Exception('product $id'));
}

class _FakeDocuments extends PurchaseOrderDocuments {
  _FakeDocuments()
    : super(
        printingRepository: PrintingRepository(PosApiService()),
        shopSettingsRepository: ShopSettingsRepository(PosApiService()),
      );

  @override
  Future<bool> print(PurchaseOrder order) async {
    await Future<void>.delayed(const Duration(milliseconds: 800));
    return true;
  }

  @override
  Future<OrderDocumentActionStatus> share(PurchaseOrder order) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return OrderDocumentActionStatus.completed;
  }
}
