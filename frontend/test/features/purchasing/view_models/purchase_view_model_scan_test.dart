import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/barcode_resolution.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';

void main() {
  const variant = ProductVariant(id: 9, productId: 5, sku: 'SGR', unitPrice: 1);

  PurchaseViewModel makeViewModel() {
    return PurchaseViewModel(
      _FakeCatalogRepository(),
      _FakePurchaseRepository(),
    );
  }

  test('a scan marks the draft line as the active one', () async {
    final viewModel = makeViewModel();

    await viewModel.addVariant(
      variant,
      unitCost: 2,
      source: 'purchase_barcode_lookup',
    );
    expect(viewModel.lastScannedDraftLine, isNotNull);
    // A scan only ever adds/increments its own product — never a typed
    // quantity — so the line stays at 1.
    expect(viewModel.draft.single.quantity, 1);
  });

  test('catalog taps mark the active line like a scan does', () async {
    final viewModel = makeViewModel();

    await viewModel.addVariant(
      variant,
      unitCost: 2,
      source: 'purchase_catalog_tile',
    );
    expect(viewModel.lastScannedDraftLine, isNotNull);
  });

  test('stepper adds do not mark an active line', () async {
    final viewModel = makeViewModel();

    await viewModel.addVariant(
      variant,
      unitCost: 2,
      source: 'purchase_draft_quantity_button',
    );
    expect(viewModel.lastScannedDraftLine, isNull);
    expect(viewModel.draft.single.quantity, 1);
  });

  test('unit switch rescales the line cost proportionally', () async {
    final viewModel = makeViewModel();
    // 0.45 per piece (per the line's base unit).
    await viewModel.addVariant(variant, unitCost: 0.45);

    // piece → tray of 30: 0.45 × 30 = 13.50 per tray.
    viewModel.updateLineUnit(
      variant,
      unitCode: 'tray',
      unitLabel: 'طبق',
      unitFactor: 30,
      allowsFractional: true,
    );
    expect(viewModel.draft.single.unitCost, 13.5);
    expect(viewModel.draft.single.unitAllowsFractional, isTrue);

    // tray → carton of 360: 13.50 / 30 × 360 = 162.00 per carton.
    viewModel.updateLineUnit(
      variant,
      unitCode: 'carton',
      unitLabel: 'كرتون',
      unitFactor: 360,
    );
    expect(viewModel.draft.single.unitCost, 162.0);

    // back to the base piece: 162 / 360 = 0.45.
    viewModel.updateLineUnit(
      variant,
      unitCode: '',
      unitLabel: '',
      unitFactor: 1,
    );
    expect(viewModel.draft.single.unitCost, 0.45);
  });

  test('a typed fraction survives a unit switch', () async {
    final viewModel = makeViewModel();
    await viewModel.addVariant(
      variant,
      unitCost: 15,
      source: 'purchase_barcode_lookup',
    );
    viewModel.updateLineUnit(
      variant,
      unitCode: 'tray',
      unitLabel: 'طبق',
      unitFactor: 30,
      allowsFractional: true,
    );

    // A fraction sticks for any unit.
    viewModel.setLineQuantity(variant, 2.5);
    expect(viewModel.draft.single.quantity, 2.5);

    // Switching to the whole-number base unit keeps the fraction untouched
    // (any unit may transact in fractions now).
    viewModel.updateLineUnit(
      variant,
      unitCode: '',
      unitLabel: '',
      unitFactor: 1,
    );
    expect(viewModel.draft.single.quantity, 2.5);
  });

  test('setLineQuantity clamps into the draft range', () async {
    final viewModel = makeViewModel();
    await viewModel.addVariant(variant, unitCost: 2);

    viewModel.setLineQuantity(variant, 5000);
    expect(viewModel.draft.single.quantity, 5000);

    viewModel.setLineQuantity(variant, 0);
    expect(viewModel.draft.single.quantity, 5000); // rejected, unchanged

    // A fraction sticks for any unit now — even the base piece unit.
    viewModel.setLineQuantity(variant, 2.5);
    expect(viewModel.draft.single.quantity, 2.5);
  });

  test(
    'resolveBarcode surfaces a failed lookup as Error, not "not found"',
    () async {
      final viewModel = PurchaseViewModel(
        _ErrorCatalogRepository(),
        _FakePurchaseRepository(),
      );

      // The distinction drives the scan chime + UI: an unreadable code must
      // not open the quick-create sheet for a product that may well exist.
      expect(
        await viewModel.resolveBarcode('1000001'),
        isA<Error<BarcodeResolution?>>(),
      );
      await expectLater(
        viewModel.findVariantByBarcode('1000001'),
        throwsA(isA<Exception>()),
      );
      // Blank input is a clean miss, not an error.
      final blank = await viewModel.resolveBarcode('  ');
      expect(blank, isA<Ok<BarcodeResolution?>>());
      expect((blank as Ok<BarcodeResolution?>).value, isNull);
    },
  );
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => const Ok(ProductVariantPage(variants: [], hasMore: false));

  @override
  Future<Result<Product>> loadProduct(int id) async =>
      Error(Exception('product $id not found'));
}

class _ErrorCatalogRepository extends _FakeCatalogRepository {
  @override
  Future<Result<BarcodeResolution?>> resolveBarcode(
    String barcode, {
    bool activeOnly = true,
  }) async => Error(Exception('catalog lookup unavailable'));
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());

  @override
  Future<Result<PurchaseDiscountPreview>> previewDiscounts(
    PurchaseDiscountPreviewDraft draft,
  ) async => Error(Exception('no preview in test'));
}
