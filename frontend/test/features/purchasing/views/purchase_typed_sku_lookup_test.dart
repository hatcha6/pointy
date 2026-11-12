import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/barcode_resolution.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_product_create.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// A code typed into the purchase order's search box and entered: no barcode
/// answers to an SKU, so the typed text is read as one before it is called an
/// unknown product — and as a search before the creation wizard is offered.
void main() {
  const juice = ProductVariant(
    id: 21,
    productId: 9,
    sku: 'JCE-003',
    productName: 'عصير برتقال',
    unitPrice: 4,
  );
  const juiceLarge = ProductVariant(
    id: 22,
    productId: 10,
    sku: 'JCE-0031',
    productName: 'عصير برتقال كبير',
    unitPrice: 7,
  );

  Future<(PurchaseViewModel, BuildContext)> pump(WidgetTester tester) async {
    final viewModel = PurchaseViewModel(
      _FakeCatalogRepository(const [juice, juiceLarge]),
      _FakePurchaseRepository(),
    );
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (viewModel, context);
  }

  testWidgets('a typed SKU adds its product, whatever its letter case', (
    tester,
  ) async {
    final (viewModel, context) = await pump(tester);

    await addScannedPurchaseBarcode(
      context,
      viewModel: viewModel,
      barcode: 'jce-003',
      typed: true,
    );
    await tester.pumpAndSettle();

    expect(viewModel.draft.single.variant.id, juice.id);
    expect(viewModel.scanStatus, PurchaseScanStatus.found);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('typed text that only finds products stays a search', (
    tester,
  ) async {
    final (viewModel, context) = await pump(tester);

    await addScannedPurchaseBarcode(
      context,
      viewModel: viewModel,
      barcode: 'JCE-00',
      typed: true,
    );
    await tester.pumpAndSettle();

    expect(viewModel.draft, isEmpty);
    // Not a failed scan: nothing says a barcode was not found.
    expect(viewModel.scanStatus, PurchaseScanStatus.idle);
    expect(find.byType(Dialog), findsNothing);
  });
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository(this.variants) : super(PosApiService());

  final List<ProductVariant> variants;

  @override
  Future<Result<BarcodeResolution?>> resolveBarcode(
    String barcode, {
    bool activeOnly = true,
  }) async => const Ok(null);

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async {
    final term = query.search.toLowerCase();
    return Ok(
      ProductVariantPage(
        variants: [
          for (final variant in variants)
            if (term.isEmpty || variant.sku.toLowerCase().contains(term))
              variant,
        ],
        hasMore: false,
      ),
    );
  }

  @override
  Future<Result<Product>> loadProduct(int id) async =>
      Error(Exception('product $id not found'));
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());

  @override
  Future<Result<double?>> loadLastProductCost(
    int productId, {
    int? variantId,
  }) async => const Ok(2);
}
