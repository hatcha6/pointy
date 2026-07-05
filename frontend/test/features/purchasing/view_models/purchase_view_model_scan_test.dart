import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
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
    return PurchaseViewModel(_FakeCatalogRepository(), _FakePurchaseRepository());
  }

  test('a scan arms the quick adjust and digits set the line quantity', () async {
    final viewModel = makeViewModel();

    await viewModel.addVariant(
      variant,
      unitCost: 2,
      source: 'purchase_barcode_lookup',
    );
    expect(viewModel.lastScannedDraftLine, isNotNull);

    expect(viewModel.applyQuickQuantityDigits('2'), isTrue);
    expect(viewModel.draft.single.quantity, 2);
    // A second digit within the idle window appends: 2 → 25.
    expect(viewModel.applyQuickQuantityDigits('5'), isTrue);
    expect(viewModel.draft.single.quantity, 25);
  });

  test('catalog taps arm the quick adjust like a scan does', () async {
    final viewModel = makeViewModel();

    await viewModel.addVariant(
      variant,
      unitCost: 2,
      source: 'purchase_catalog_tile',
    );
    expect(viewModel.lastScannedDraftLine, isNotNull);
    expect(viewModel.applyQuickQuantityDigits('7'), isTrue);
    expect(viewModel.draft.single.quantity, 7);
  });

  test('stepper adds do not arm the quick adjust', () async {
    final viewModel = makeViewModel();

    await viewModel.addVariant(
      variant,
      unitCost: 2,
      source: 'purchase_draft_quantity_button',
    );
    expect(viewModel.lastScannedDraftLine, isNull);
    expect(viewModel.applyQuickQuantityDigits('7'), isFalse);
    expect(viewModel.draft.single.quantity, 1);
  });

  test('setLineQuantity clamps into the draft range', () async {
    final viewModel = makeViewModel();
    await viewModel.addVariant(variant, unitCost: 2);

    viewModel.setLineQuantity(variant, 5000);
    expect(viewModel.draft.single.quantity, 999);

    viewModel.setLineQuantity(variant, 0);
    expect(viewModel.draft.single.quantity, 999); // rejected, unchanged
  });
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

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());

  @override
  Future<Result<PurchaseDiscountPreview>> previewDiscounts(
    PurchaseDiscountPreviewDraft draft,
  ) async => Error(Exception('no preview in test'));
}
