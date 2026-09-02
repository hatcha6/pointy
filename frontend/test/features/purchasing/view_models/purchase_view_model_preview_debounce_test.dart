import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';

/// The PO editor re-previews on every edit. Field telemetry showed a third of
/// all purchasing previews arriving within half a second of the previous one
/// (a held +/− key, a typed quantity): one server round trip per keystroke.
/// Edits that land inside the debounce window fold into ONE request.
void main() {
  const supplier = SupplierContact(
    id: 3,
    name: 'ACME',
    contactName: '',
    phone: '',
    email: '',
    address: '',
    notes: '',
    isActive: true,
  );
  const variant = ProductVariant(id: 9, productId: 5, sku: 'SGR', unitPrice: 1);

  test('rapid draft edits produce one preview request', () async {
    final purchase = _CountingPurchaseRepository();
    final vm = PurchaseViewModel(
      _StubCatalogRepository(),
      purchase,
      discountPreviewDebounce: const Duration(milliseconds: 40),
    );
    vm.selectSupplier(supplier);
    await vm.addVariant(variant, unitCost: 2);

    // Three edits well inside the window, awaited together: the futures all
    // settle on the one preview that finally runs.
    await Future.wait([
      vm.refreshDiscountPreview(),
      vm.refreshDiscountPreview(),
      vm.refreshDiscountPreview(),
    ]);

    expect(purchase.previewCalls, 1);
    expect(vm.discountPreview, isNotNull);
    vm.dispose();
  });

  test('edits separated by more than the window preview separately', () async {
    final purchase = _CountingPurchaseRepository();
    final vm = PurchaseViewModel(
      _StubCatalogRepository(),
      purchase,
      discountPreviewDebounce: const Duration(milliseconds: 20),
    );
    vm.selectSupplier(supplier);
    await vm.addVariant(variant, unitCost: 2);
    await vm.refreshDiscountPreview();
    await vm.refreshDiscountPreview();

    expect(purchase.previewCalls, 2);
    vm.dispose();
  });
}

class _StubCatalogRepository extends CatalogRepository {
  _StubCatalogRepository() : super(PosApiService());

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => const Ok(ProductVariantPage(variants: [], hasMore: false));
}

class _CountingPurchaseRepository extends PurchaseRepository {
  _CountingPurchaseRepository() : super(PosApiService());

  int previewCalls = 0;

  @override
  Future<Result<PurchaseDiscountPreview>> previewDiscounts(
    PurchaseDiscountPreviewDraft draft,
  ) async {
    previewCalls += 1;
    return Ok(
      PurchaseDiscountPreview(
        subtotal: 2,
        discountTotal: 0,
        landedCostTotal: 0,
        total: 2,
        lines: const [],
        appliedDiscounts: const [],
      ),
    );
  }
}
