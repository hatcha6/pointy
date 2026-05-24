import '../../core/result.dart';
import '../models/attachment_summary.dart';
import '../models/product.dart';
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
  }) async {
    return Result.guard(
      () => _service.searchProductImages(query: query, page: page),
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

  Future<Result<ProductVariant?>> findProductVariantByBarcode(
    String barcode, {
    bool activeOnly = true,
  }) async {
    final normalizedBarcode = barcode.trim();
    if (normalizedBarcode.isEmpty) {
      return const Ok(null);
    }

    final query = ProductQuery(
      barcode: normalizedBarcode,
      availability: activeOnly
          ? ProductAvailabilityFilter.active
          : ProductAvailabilityFilter.all,
    );

    return Result.guard(() async {
      final page = await _service.fetchProductVariants(query: query, page: 1);
      for (final variant in page.variants) {
        if (variant.barcode.trim() == normalizedBarcode) {
          return variant;
        }
      }
      return null;
    });
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
