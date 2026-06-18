import '../../core/result.dart';
import '../../shared/barcode/scale_barcode.dart';
import '../models/attachment_summary.dart';
import '../models/modifier_group.dart';
import '../models/product.dart';
import '../models/product_bulk_action.dart';
import '../models/unit_of_measure.dart';
import '../models/product_category.dart';
import '../models/product_category_query.dart';
import '../models/product_draft.dart';
import '../models/product_image_search_result.dart';
import '../models/product_image_upload.dart';
import '../models/product_page.dart';
import '../models/product_query.dart';
import '../models/product_update_draft.dart';
import '../models/product_variant.dart';
import '../models/product_variant_draft.dart';
import '../models/product_variant_page.dart';
import '../models/variant_option.dart';
import '../models/variant_option_draft.dart';
import '../models/variant_option_page.dart';
import '../models/variant_option_query.dart';
import '../models/variant_option_value.dart';
import '../models/variant_option_value_draft.dart';
import '../models/variant_option_value_page.dart';
import '../models/variant_option_value_query.dart';
import '../services/pos_api_service.dart';

class CatalogRepository {
  CatalogRepository(this._service);

  final PosApiService _service;

  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
  }) async {
    return Result.guard(() => _service.fetchProducts(query: query, page: page));
  }

  Future<Result<Product>> createProduct(ProductDraft draft) async {
    return Result.guard(() => _service.createProduct(draft));
  }

  Future<Result<Product>> updateProduct({
    required int id,
    required ProductUpdateDraft draft,
  }) async {
    return Result.guard(() => _service.updateProduct(id: id, draft: draft));
  }

  Future<Result<Product>> loadProduct(int id) async {
    return Result.guard(() => _service.fetchProduct(id));
  }

  Future<Result<Product>> archiveProduct(int id) async {
    return Result.guard(() => _service.archiveProduct(id));
  }

  Future<Result<Product>> restoreProduct(int id) async {
    return Result.guard(() => _service.restoreProduct(id));
  }

  Future<Result<int>> bulkArchiveProducts({
    required List<int> ids,
    required bool archived,
  }) async {
    return Result.guard(
      () => _service.bulkArchiveProducts(ids: ids, archived: archived),
    );
  }

  Future<Result<int>> bulkRepriceProducts({
    required List<int> ids,
    required ProductBulkRepriceMode mode,
    required double value,
  }) async {
    return Result.guard(
      () => _service.bulkRepriceProducts(
        ids: ids,
        mode: mode.apiValue,
        value: value,
      ),
    );
  }

  Future<Result<int>> bulkCategorizeProducts({
    required List<int> ids,
    required List<int> categoryIds,
    required ProductBulkCategorizeMode mode,
  }) async {
    return Result.guard(
      () => _service.bulkCategorizeProducts(
        ids: ids,
        categoryIds: categoryIds,
        mode: mode.apiValue,
      ),
    );
  }

  Future<Result<int>> bulkSetProductFlags({
    required List<int> ids,
    bool? isActive,
    bool? tracksExpiry,
    bool? isService,
    bool? isPrepared,
  }) async {
    return Result.guard(
      () => _service.bulkSetProductFlags(
        ids: ids,
        isActive: isActive,
        tracksExpiry: tracksExpiry,
        isService: isService,
        isPrepared: isPrepared,
      ),
    );
  }

  Future<Result<AttachmentSummary>> uploadProductImage({
    required int productId,
    required ProductImageUpload upload,
  }) async {
    return Result.guard(
      () => _service.uploadProductImage(productId: productId, upload: upload),
    );
  }

  Future<Result<AttachmentSummary>> importProductImage({
    required int productId,
    required String importToken,
  }) async {
    return Result.guard(
      () => _service.importProductImage(
        productId: productId,
        importToken: importToken,
      ),
    );
  }

  Future<Result<List<ProductImageSearchResult>>> searchProductImages({
    required String query,
    int page = 1,
    int? pageSize,
  }) async {
    return Result.guard(
      () => _service.searchProductImages(
        query: query,
        page: page,
        pageSize: pageSize,
      ),
    );
  }

  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchProductVariants(query: query, page: page),
    );
  }

  Future<Result<ProductVariantPage>> loadVariantsForProduct(
    int productId, {
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchVariantsForProduct(productId, page: page),
    );
  }

  Future<Result<ProductVariant>> createProductVariant(
    ProductVariantDraft draft,
  ) async {
    return Result.guard(() => _service.createProductVariant(draft));
  }

  Future<Result<ProductVariant>> createVariantForProduct(
    int productId,
    ProductVariantDraft draft,
  ) async {
    return Result.guard(
      () => _service.createVariantForProduct(productId, draft),
    );
  }

  Future<Result<ProductVariant>> updateProductVariant({
    required int id,
    required ProductVariantDraft draft,
  }) async {
    return Result.guard(
      () => _service.updateProductVariant(id: id, draft: draft),
    );
  }

  Future<Result<void>> deleteProductVariant(int id) async {
    return Result.guard(() => _service.deleteProductVariant(id));
  }

  Future<Result<ProductCategoryPage>> loadProductCategories({
    ProductCategoryQuery query = const ProductCategoryQuery(),
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchProductCategories(query: query, page: page),
    );
  }

  Future<Result<ProductCategory>> createProductCategory(
    ProductCategoryDraft draft,
  ) async {
    return Result.guard(() => _service.createProductCategory(draft));
  }

  Future<Result<ProductCategory>> updateProductCategory({
    required int id,
    required ProductCategoryDraft draft,
  }) async {
    return Result.guard(
      () => _service.updateProductCategory(id: id, changes: draft.toJson()),
    );
  }

  /// Pin/unpin a category from the quick-access filter strip without touching
  /// its other fields.
  Future<Result<ProductCategory>> setCategoryQuickAccess({
    required int id,
    required bool isQuickAccess,
  }) async {
    return Result.guard(
      () => _service.updateProductCategory(
        id: id,
        changes: {'is_quick_access': isQuickAccess},
      ),
    );
  }

  /// Persist the order of the quick-access strip. [orderedIds] is the desired
  /// order; each category's `display_order` is set to its index.
  Future<Result<void>> reorderQuickAccessCategories(
    List<int> orderedIds,
  ) async {
    return Result.guard(() async {
      for (var index = 0; index < orderedIds.length; index += 1) {
        await _service.updateProductCategory(
          id: orderedIds[index],
          changes: {'display_order': index},
        );
      }
    });
  }

  Future<Result<void>> deleteProductCategory(int id) async {
    return Result.guard(() => _service.deleteProductCategory(id));
  }

  /// All active quick-access categories, ordered for the POS/purchasing strip.
  Future<Result<List<ProductCategory>>> loadQuickAccessCategories() async {
    return Result.guard(() async {
      final categories = <ProductCategory>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchProductCategories(
          query: const ProductCategoryQuery(
            availability: ProductCategoryAvailabilityFilter.active,
            ordering: ProductCategoryOrdering.manual,
            quickAccessOnly: true,
          ),
          page: page,
        );
        categories.addAll(result.categories);
        hasMore = result.hasMore;
        page += 1;
      }
      return categories;
    });
  }

  Future<Result<VariantOptionValuePage>> loadVariantOptionValues({
    VariantOptionValueQuery query = const VariantOptionValueQuery(),
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchVariantOptionValues(query: query, page: page),
    );
  }

  Future<Result<VariantOptionValue>> createVariantOptionValue(
    VariantOptionValueDraft draft,
  ) async {
    return Result.guard(() => _service.createVariantOptionValue(draft));
  }

  Future<Result<VariantOptionPage>> loadVariantOptions({
    VariantOptionQuery query = const VariantOptionQuery(),
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchVariantOptions(query: query, page: page),
    );
  }

  Future<Result<VariantOption>> createVariantOption(
    VariantOptionDraft draft,
  ) async {
    return Result.guard(() => _service.createVariantOption(draft));
  }

  Future<Result<List<VariantOption>>> loadAllActiveVariantOptions() async {
    return Result.guard(() async {
      final options = <VariantOption>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchVariantOptions(
          query: const VariantOptionQuery(
            availability: VariantOptionAvailabilityFilter.active,
          ),
          page: page,
        );
        options.addAll(result.options);
        hasMore = result.hasMore;
        page += 1;
      }
      return options;
    });
  }

  Future<Result<List<ModifierGroup>>> loadAllModifierGroups() async {
    return Result.guard(() async {
      final groups = <ModifierGroup>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchModifierGroups(page: page);
        groups.addAll(result.groups);
        hasMore = result.hasMore;
        page += 1;
      }
      return groups;
    });
  }

  Future<Result<List<UnitOfMeasure>>> loadAllUnits({
    bool activeOnly = true,
  }) async {
    return Result.guard(() async {
      final units = <UnitOfMeasure>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchUnitsOfMeasure(
          page: page,
          active: activeOnly ? true : null,
        );
        units.addAll(result.units);
        hasMore = result.hasMore;
        page += 1;
      }
      units.sort((a, b) => a.displayOrder.compareTo(b.displayOrder));
      return units;
    });
  }

  Future<Result<UnitOfMeasure>> createUnit(UnitOfMeasureDraft draft) async {
    return Result.guard(() => _service.createUnitOfMeasure(draft));
  }

  Future<Result<UnitOfMeasure>> updateUnit({
    required int id,
    required UnitOfMeasureDraft draft,
  }) async {
    return Result.guard(
      () => _service.updateUnitOfMeasure(id: id, changes: draft.toJson()),
    );
  }

  Future<Result<void>> deleteUnit(int id) async {
    return Result.guard(() => _service.deleteUnitOfMeasure(id));
  }

  /// Persists a new ordering by patching each unit's display_order to its index.
  Future<Result<void>> reorderUnits(List<int> orderedUnitIds) async {
    return Result.guard(() async {
      for (var index = 0; index < orderedUnitIds.length; index += 1) {
        await _service.updateUnitOfMeasure(
          id: orderedUnitIds[index],
          changes: {'display_order': index},
        );
      }
    });
  }

  Future<Result<ProductVariant?>> findProductVariantByBarcode(
    String barcode, {
    bool activeOnly = true,
  }) async {
    final normalizedBarcode = barcode.trim();
    if (normalizedBarcode.isEmpty) {
      return const Ok(null);
    }

    return Result.guard(() async {
      final direct = await _findVariantByExactBarcode(
        normalizedBarcode,
        activeOnly: activeOnly,
      );
      if (direct != null) {
        return direct;
      }
      // Digital-scale labels embed the weight in the barcode; the catalog
      // stores only the short item code, so retry with the parsed candidates.
      final scaleBarcode = parseScaleBarcode(normalizedBarcode);
      if (scaleBarcode == null) {
        return null;
      }
      for (final candidate in scaleBarcode.candidateBarcodes) {
        final variant = await _findVariantByExactBarcode(
          candidate,
          activeOnly: activeOnly,
        );
        if (variant != null) {
          return variant;
        }
      }
      return null;
    });
  }

  Future<ProductVariant?> _findVariantByExactBarcode(
    String barcode, {
    required bool activeOnly,
  }) async {
    final page = await _service.fetchProductVariants(
      query: ProductQuery(
        barcode: barcode,
        availability: activeOnly
            ? ProductAvailabilityFilter.active
            : ProductAvailabilityFilter.all,
      ),
      page: 1,
    );
    for (final variant in page.variants) {
      if (variant.barcode.trim() == barcode) {
        return variant;
      }
    }
    return null;
  }

  List<ProductVariant> sampleProductVariants(ProductQuery query) {
    final variants = const [
      ProductVariant(
        id: 1,
        productId: 1,
        productName: 'قهوة البيت',
        displayName: 'قهوة البيت',
        fullName: 'قهوة البيت',
        sku: 'COF-001',
        unitPrice: 3.50,
        barcode: '1000001',
        quantityOnHand: 12,
        isDefault: true,
      ),
      ProductVariant(
        id: 2,
        productId: 2,
        productName: 'شاي بالنعناع',
        displayName: 'شاي بالنعناع',
        fullName: 'شاي بالنعناع',
        sku: 'TEA-001',
        unitPrice: 2.75,
        barcode: '1000002',
        quantityOnHand: 12,
        isDefault: true,
      ),
      ProductVariant(
        id: 3,
        productId: 3,
        productName: 'لوح تمر',
        displayName: 'لوح تمر',
        fullName: 'لوح تمر',
        sku: 'SNK-012',
        unitPrice: 1.95,
        barcode: '1000003',
        quantityOnHand: 12,
        isDefault: true,
      ),
      ProductVariant(
        id: 4,
        productId: 4,
        productName: 'كرواسون زعتر',
        displayName: 'كرواسون زعتر',
        fullName: 'كرواسون زعتر',
        sku: 'BKR-044',
        unitPrice: 4.25,
        barcode: '1000004',
        quantityOnHand: 12,
        isDefault: true,
      ),
      ProductVariant(
        id: 5,
        productId: 5,
        productName: 'عصير برتقال',
        displayName: 'عصير برتقال',
        fullName: 'عصير برتقال',
        sku: 'JCE-002',
        unitPrice: 3.25,
        barcode: '1000005',
        quantityOnHand: 12,
        isDefault: true,
      ),
      ProductVariant(
        id: 6,
        productId: 6,
        productName: 'ساندويتش حلومي',
        displayName: 'ساندويتش حلومي',
        fullName: 'ساندويتش حلومي',
        sku: 'SND-019',
        unitPrice: 6.80,
        barcode: '1000006',
        quantityOnHand: 12,
        isDefault: true,
      ),
    ];

    final search = query.search.trim().toLowerCase();
    final barcode = query.barcode.trim();
    final filtered = variants
        .where((variant) {
          final matchesSearch =
              search.isEmpty ||
              variant.displayLabel.toLowerCase().contains(search) ||
              variant.productName.toLowerCase().contains(search) ||
              variant.sku.toLowerCase().contains(search) ||
              variant.barcode.toLowerCase().contains(search);
          final matchesBarcode = barcode.isEmpty || variant.barcode == barcode;
          return matchesSearch && matchesBarcode;
        })
        .toList(growable: false);

    final sorted = [...filtered];
    sorted.sort((a, b) {
      return switch (query.ordering) {
        ProductOrdering.name => a.displayLabel.compareTo(b.displayLabel),
        ProductOrdering.priceAsc => a.unitPrice.compareTo(b.unitPrice),
        ProductOrdering.priceDesc => b.unitPrice.compareTo(a.unitPrice),
        ProductOrdering.newest => b.id.compareTo(a.id),
      };
    });
    return sorted;
  }

  List<Product> sampleProducts(ProductQuery query) {
    if (query.categories.isEmpty) {
      return sampleProductVariants(
        query,
      ).map(Product.fromVariant).toList(growable: false);
    }
    return const [];
  }
}
