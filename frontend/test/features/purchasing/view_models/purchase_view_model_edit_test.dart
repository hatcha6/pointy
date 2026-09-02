import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_unit.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';

void main() {
  PurchaseOrder draftOrder({
    required List<PurchaseOrderLine> lines,
    List<String> discountCodes = const [],
    String status = 'draft',
  }) {
    return PurchaseOrder(
      id: 42,
      orderNumber: 'P-42',
      status: status,
      lineCount: lines.length,
      total: 24,
      subtotal: 24,
      lines: lines,
      adjustments: const [],
      receipts: const [],
      canReturn: false,
      canRefund: false,
      canExchange: false,
      supplierId: 3,
      supplierName: 'ACME',
      discountCodes: discountCodes,
    );
  }

  PurchaseOrderLine orderLine({
    required int productId,
    required int variantId,
    String unit = '',
    String unitLabel = '',
  }) {
    return PurchaseOrderLine(
      id: 1,
      productId: productId,
      variantId: variantId,
      quantity: 2,
      adjustedQuantity: 0,
      adjustableQuantity: 0,
      receivedQuantity: 0,
      damagedQuantity: 0,
      rejectedQuantity: 0,
      openQuantity: 2,
      hasReceivingTotals: false,
      unitCost: 12,
      unit: unit,
      unitLabel: unitLabel,
      total: 24,
    );
  }

  Product boxProduct() {
    const variant = ProductVariant(
      id: 9,
      productId: 5,
      sku: 'SGR',
      unitPrice: 1,
    );
    return Product(
      id: 5,
      name: 'Sugar',
      quantityOnHand: 0,
      units: const [
        ProductUnit(
          unit: UnitOfMeasure(id: 1, code: 'box', name: 'Box'),
          factorToBase: 12,
        ),
      ],
      defaultVariant: variant,
      variants: const [variant],
    );
  }

  test('loadOrderForEditing rebuilds draft lines with the resolved unit and '
      'attached product detail', () async {
    final catalog = _FakeCatalogRepository({5: boxProduct()});
    final vm = PurchaseViewModel(catalog, _FakePurchaseRepository());

    await vm.loadOrderForEditing(
      draftOrder(
        lines: [orderLine(productId: 5, variantId: 9, unit: 'box')],
        discountCodes: const ['SAVE'],
      ),
    );

    expect(vm.isEditing, isTrue);
    expect(vm.editingOrderId, 42);
    expect(vm.selectedSupplier?.id, 3);
    expect(vm.discountCode, 'SAVE');
    expect(vm.unresolvedEditLineNames, isEmpty);

    final line = vm.draft.single;
    expect(line.variant.id, 9);
    expect(line.quantity, 2);
    expect(line.unitCost, 12);
    expect(line.unitCode, 'box');
    expect(line.unitFactor, 12); // resolved from the product's box unit
    expect(line.variant.productDetail, isNotNull);
  });

  test(
    'loadOrderForEditing resolves every line with one catalog request',
    () async {
      final catalog = _FakeCatalogRepository({5: boxProduct()});
      final vm = PurchaseViewModel(catalog, _FakePurchaseRepository());

      await vm.loadOrderForEditing(
        draftOrder(
          lines: [
            orderLine(productId: 5, variantId: 9, unit: 'box'),
            orderLine(productId: 5, variantId: 9),
            orderLine(productId: 77, variantId: 78),
          ],
        ),
      );

      // One bulk request carrying each product id once — never a
      // product-detail fetch per line.
      expect(catalog.bulkRequests, [
        [5, 77],
      ]);
      expect(catalog.singleLoads, 0);
      expect(vm.draft, hasLength(2));
      expect(vm.unresolvedEditLineNames, hasLength(1));
    },
  );

  test('loadOrderForEditing falls back to per-product loads when the bulk '
      'request fails', () async {
    final catalog = _FakeCatalogRepository({
      5: boxProduct(),
    }, bulkLoadFails: true);
    final vm = PurchaseViewModel(catalog, _FakePurchaseRepository());

    await vm.loadOrderForEditing(
      draftOrder(lines: [orderLine(productId: 5, variantId: 9, unit: 'box')]),
    );

    expect(catalog.bulkRequests, hasLength(1));
    expect(catalog.singleLoads, 1);
    expect(vm.draft.single.variant.id, 9);
    expect(vm.unresolvedEditLineNames, isEmpty);
  });

  test('loadOrderForEditing records lines whose product can no longer be '
      'resolved', () async {
    final catalog = _FakeCatalogRepository(const {}); // no products available
    final vm = PurchaseViewModel(catalog, _FakePurchaseRepository());

    await vm.loadOrderForEditing(
      draftOrder(lines: [orderLine(productId: 99, variantId: 1)]),
    );

    expect(vm.draft, isEmpty);
    expect(vm.unresolvedEditLineNames, hasLength(1));
  });

  test('editing an order past draft carries the submit-time rules', () async {
    final catalog = _FakeCatalogRepository({5: boxProduct()});
    final vm = PurchaseViewModel(catalog, _FakePurchaseRepository());
    final lines = [orderLine(productId: 5, variantId: 9, unit: 'box')];

    await vm.loadOrderForEditing(draftOrder(lines: lines));
    expect(vm.isEditingCommittedOrder, isFalse);
    expect(vm.isEditingReceivedOrder, isFalse);

    await vm.loadOrderForEditing(draftOrder(lines: lines, status: 'submitted'));
    // Expected stock is rebuilt on save, so expiry dates are due now.
    expect(vm.isEditingCommittedOrder, isTrue);
    expect(vm.isEditingReceivedOrder, isFalse);

    await vm.loadOrderForEditing(draftOrder(lines: lines, status: 'received'));
    // Saving also puts the delivery back — the editor says so up front.
    expect(vm.isEditingReceivedOrder, isTrue);
  });

  test('saveDraft updates the edited order via the repository', () async {
    final catalog = _FakeCatalogRepository({5: boxProduct()});
    final purchase = _FakePurchaseRepository();
    final vm = PurchaseViewModel(catalog, purchase);

    await vm.loadOrderForEditing(
      draftOrder(lines: [orderLine(productId: 5, variantId: 9, unit: 'box')]),
    );
    final result = await vm.saveDraft();

    expect(result, isA<Ok<PurchaseOrder>>());
    expect(purchase.lastUpdateOrderId, 42);
    expect(purchase.lastUpdateSupplierId, 3);
    expect(purchase.lastUpdateLines, hasLength(1));
    expect(purchase.lastUpdateLines!.single.variant.id, 9);
  });

  test('saveDraft is rejected when not editing', () async {
    final vm = PurchaseViewModel(
      _FakeCatalogRepository(const {}),
      _FakePurchaseRepository(),
    );

    final result = await vm.saveDraft();

    expect(result, isA<Error<PurchaseOrder>>());
    expect(vm.isEditing, isFalse);
  });
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository(this._products, {this.bulkLoadFails = false})
    : super(PosApiService());

  final Map<int, Product> _products;
  final bool bulkLoadFails;
  final List<List<int>> bulkRequests = [];
  int singleLoads = 0;

  @override
  Future<Result<List<Product>>> loadProductsByIds(List<int> ids) async {
    bulkRequests.add(List.of(ids));
    if (bulkLoadFails) {
      return Error(Exception('bulk load unavailable'));
    }
    return Ok([for (final id in ids) ?_products[id]]);
  }

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => const Ok(ProductVariantPage(variants: [], hasMore: false));

  @override
  Future<Result<Product>> loadProduct(int id) async {
    singleLoads += 1;
    final product = _products[id];
    return product == null
        ? Error(Exception('product $id not found'))
        : Ok(product);
  }
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());

  int? lastUpdateOrderId;
  int? lastUpdateSupplierId;
  List<PurchaseDraftLine>? lastUpdateLines;

  @override
  Future<Result<PurchaseDiscountPreview>> previewDiscounts(
    PurchaseDiscountPreviewDraft draft,
  ) async => Error(Exception('no preview in test'));

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
  }) async {
    lastUpdateOrderId = purchaseOrderId;
    lastUpdateSupplierId = supplierId;
    lastUpdateLines = lines;
    return Ok(
      PurchaseOrder(
        id: purchaseOrderId,
        orderNumber: 'P-$purchaseOrderId',
        status: 'draft',
        lineCount: lines.length,
        total: 0,
        subtotal: 0,
        lines: const [],
        adjustments: const [],
        receipts: const [],
        canReturn: false,
        canRefund: false,
        canExchange: false,
      ),
    );
  }
}
