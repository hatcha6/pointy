import '../models/attachment_summary.dart';
import '../models/bought_together_product.dart';
import '../models/catalog_identity_conflict.dart';
import '../models/product.dart';
import '../models/product_category.dart';
import '../models/product_draft.dart';
import '../models/product_image_search_result.dart';
import '../models/product_image_upload.dart';
import '../models/product_page.dart';
import '../models/product_update_draft.dart';
import '../models/product_variant.dart';
import '../models/product_variant_draft.dart';
import '../models/product_variant_page.dart';
import '../models/query.dart';
import '../models/variant_option.dart';
import '../models/variant_option_draft.dart';
import '../models/variant_option_page.dart';
import '../models/variant_option_query.dart';
import '../models/variant_option_value.dart';
import '../models/variant_option_value_draft.dart';
import '../models/variant_option_value_page.dart';
import 'api_session.dart';

/// How many variant ids one `?ids=` request may carry: the server's catalog
/// page size. A longer set is split into several requests.
const int catalogVariantIdBatchSize = 50;

class CatalogApiClient {
  const CatalogApiClient(this._session);

  final PosApiSession _session;

  Future<ProductPage> fetchProducts({
    required ModelQuery query,
    int page = 1,
  }) async {
    final response = await _session.get(
      'products/',
      query: query.toQueryParameters(page: page),
      // The heaviest payload in the app, re-fetched on every POS screen visit:
      // revalidate with If-None-Match so an unchanged catalog is a wire-cheap
      // 304 replayed from the session cache.
      conditionalCache: true,
    );
    _session.ensureSuccess(response, 'Product request failed with status');
    return ProductPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Product> fetchProduct(int id) async {
    final response = await _session.get('products/$id/');
    _session.ensureSuccess(
      response,
      'Product detail request failed with status',
    );
    return Product.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<BoughtTogetherProduct>> fetchBoughtTogether(
    int productId, {
    int limit = 8,
  }) async {
    final response = await _session.get(
      'products/$productId/bought-together/',
      query: {'limit': '$limit'},
    );
    _session.ensureSuccess(
      response,
      'Bought-together request failed with status',
    );
    final decoded = _session.decodedBody(response);
    final results = decoded is Map<String, Object?> ? decoded['results'] : null;
    if (results is! List<Object?>) {
      return const [];
    }
    return results
        .whereType<Map<String, Object?>>()
        .map(BoughtTogetherProduct.fromJson)
        .toList(growable: false);
  }

  Future<Product> createProduct(ProductDraft draft) async {
    final response = await _session.post('products/', body: draft.toJson());
    // throwApiException, not ensureSuccess: a rejected create carries per-field
    // errors (a duplicate SKU/barcode) in its body, and a plain Exception would
    // drop them before the form could mark the offending input.
    _session.throwApiException(response, 'Product create failed with status');
    return Product.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Product> updateProduct({
    required int id,
    required ProductUpdateDraft draft,
  }) async {
    final response = await _session.patch(
      'products/$id/',
      body: draft.toJson(),
    );
    _session.throwApiException(response, 'Product update failed with status');
    return Product.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Product> archiveProduct(int id) async {
    final response = await _session.post('products/$id/archive/');
    _session.ensureSuccess(response, 'Product archive failed with status');
    return Product.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Product> restoreProduct(int id) async {
    final response = await _session.post('products/$id/restore/');
    _session.ensureSuccess(response, 'Product restore failed with status');
    return Product.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<int> bulkArchiveProducts({
    required List<int> ids,
    required bool archived,
  }) async {
    final response = await _session.post(
      'products/bulk-archive/',
      body: {'ids': ids, 'archived': archived},
    );
    _session.ensureSuccess(response, 'Bulk archive failed with status');
    return _updatedCount(_session.decodedBody(response));
  }

  Future<int> bulkRepriceProducts({
    required List<int> ids,
    required String mode,
    required double value,
  }) async {
    final response = await _session.post(
      'products/bulk-reprice/',
      body: {'ids': ids, 'mode': mode, 'value': value.toStringAsFixed(2)},
    );
    _session.ensureSuccess(response, 'Bulk reprice failed with status');
    return _updatedCount(_session.decodedBody(response));
  }

  Future<Product> setVariantPrices({
    required int productId,
    required Map<int, double> pricesByVariant,
  }) async {
    final response = await _session.post(
      'products/$productId/set-variant-prices/',
      body: {
        'prices': [
          for (final entry in pricesByVariant.entries)
            {
              'variant': entry.key,
              'unit_price': entry.value.toStringAsFixed(2),
            },
        ],
      },
    );
    _session.ensureSuccess(response, 'Set variant prices failed with status');
    return Product.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<int> bulkCategorizeProducts({
    required List<int> ids,
    required List<int> categoryIds,
    required String mode,
  }) async {
    final response = await _session.post(
      'products/bulk-categorize/',
      body: {'ids': ids, 'category_ids': categoryIds, 'mode': mode},
    );
    _session.ensureSuccess(response, 'Bulk categorize failed with status');
    return _updatedCount(_session.decodedBody(response));
  }

  Future<int> bulkSetProductFlags({
    required List<int> ids,
    bool? isActive,
    bool? tracksExpiry,
    bool? isService,
    bool? isPrepared,
  }) async {
    final body = <String, Object?>{'ids': ids};
    if (isActive != null) body['is_active'] = isActive;
    if (tracksExpiry != null) body['tracks_expiry'] = tracksExpiry;
    if (isService != null) body['is_service'] = isService;
    if (isPrepared != null) body['is_prepared'] = isPrepared;
    final response = await _session.post(
      'products/bulk-set-flags/',
      body: body,
    );
    _session.ensureSuccess(response, 'Bulk flags failed with status');
    return _updatedCount(_session.decodedBody(response));
  }

  int _updatedCount(Object? decoded) {
    if (decoded is Map<String, Object?>) {
      final updated = decoded['updated'];
      if (updated is num) {
        return updated.toInt();
      }
    }
    return 0;
  }

  Future<AttachmentSummary> uploadProductImage({
    required int productId,
    required ProductImageUpload upload,
  }) async {
    final response = await _session.postMultipart(
      'products/$productId/attachments/',
      fields: const {'role': 'product_image', 'is_primary': 'true'},
      files: [
        ApiMultipartFile(
          fieldName: 'file',
          filename: upload.filename,
          bytes: upload.bytes,
          contentType: upload.contentType,
        ),
      ],
    );
    _session.ensureSuccess(response, 'Product image upload failed with status');
    return AttachmentSummary.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<AttachmentSummary> importProductImage({
    required int productId,
    required String importToken,
  }) async {
    final response = await _session.post(
      'products/$productId/image-import/',
      body: {'import_token': importToken, 'is_primary': true},
    );
    _session.ensureSuccess(response, 'Product image import failed with status');
    return AttachmentSummary.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<List<ProductImageSearchResult>> searchProductImages({
    required String query,
    int page = 1,
    int? pageSize,
  }) async {
    final queryParameters = <String, String>{'q': query, 'page': '$page'};
    if (pageSize != null) {
      queryParameters['page_size'] = '$pageSize';
    }
    final response = await _session.get(
      'products/image-search/',
      query: queryParameters,
    );
    _session.ensureSuccess(response, 'Product image search failed with status');
    final decoded = _session.decodedBody(response);
    final results = decoded is Map<String, Object?> ? decoded['results'] : null;
    if (results is! List<Object?>) {
      return const [];
    }
    return results
        .whereType<Map<String, Object?>>()
        .map(ProductImageSearchResult.fromJson)
        .toList(growable: false);
  }

  Future<ProductVariantPage> fetchProductVariants({
    required ModelQuery query,
    int page = 1,
  }) async {
    final response = await _session.get(
      'product-variants/',
      query: query.toQueryParameters(page: page),
      conditionalCache: true,
    );
    _session.ensureSuccess(
      response,
      'Product variant request failed with status',
    );
    return ProductVariantPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Fetches an exact set of variants by id — one request for a whole set
  /// instead of a product fetch per item. Used by the purchasing draft to
  /// refresh the selling price of every line it restored from local storage.
  ///
  /// [ids] must not exceed the server's page size (see
  /// [catalogVariantIdBatchSize]); callers with more send several batches.
  Future<ProductVariantPage> fetchVariantsByIds(List<int> ids) async {
    final response = await _session.get(
      'product-variants/',
      query: {'ids': ids.join(',')},
      conditionalCache: true,
    );
    _session.ensureSuccess(
      response,
      'Product variant request failed with status',
    );
    return ProductVariantPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Asks whether a SKU / barcode is still free — the probe both product
  /// dialogs run while the user types, so a code already owned by another
  /// product is named on the field instead of blowing up the save.
  ///
  /// Answers about archived products too: their codes stay claimed at the
  /// unique index even though they never appear in the catalog list.
  Future<CatalogIdentityCheck> checkVariantIdentity({
    String sku = '',
    String barcode = '',
    int? excludeVariantId,
  }) async {
    final response = await _session.get(
      'product-variants/identity-check/',
      query: {
        if (sku.trim().isNotEmpty) 'sku': sku.trim(),
        if (barcode.trim().isNotEmpty) 'barcode': barcode.trim(),
        if (excludeVariantId != null) 'exclude_variant': '$excludeVariantId',
      },
    );
    _session.ensureSuccess(response, 'Identity check failed with status');
    return CatalogIdentityCheck.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ProductVariantPage> fetchVariantsForProduct(
    int productId, {
    int page = 1,
  }) async {
    final response = await _session.get(
      'products/$productId/variants/',
      query: {'page': '$page'},
    );
    _session.ensureSuccess(
      response,
      'Product variant request failed with status',
    );
    return ProductVariantPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ProductVariant> createProductVariant(ProductVariantDraft draft) async {
    final response = await _session.post(
      'product-variants/',
      body: draft.toJson(),
    );
    _session.throwApiException(
      response,
      'Product variant create failed with status',
    );
    return ProductVariant.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ProductVariant> createVariantForProduct(
    int productId,
    ProductVariantDraft draft,
  ) async {
    final response = await _session.post(
      'products/$productId/variants/',
      body: draft.toJson(includeProduct: false),
    );
    _session.throwApiException(
      response,
      'Product variant create failed with status',
    );
    return ProductVariant.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ProductVariant> updateProductVariant({
    required int id,
    required ProductVariantDraft draft,
  }) async {
    final response = await _session.patch(
      'product-variants/$id/',
      body: draft.toJson(),
    );
    _session.throwApiException(
      response,
      'Product variant update failed with status',
    );
    return ProductVariant.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteProductVariant(int id) async {
    final response = await _session.delete('product-variants/$id/');
    _session.ensureSuccess(
      response,
      'Product variant delete failed with status',
    );
  }

  Future<ProductCategoryPage> fetchProductCategories({
    required ModelQuery query,
    int page = 1,
  }) async {
    final response = await _session.get(
      'product-categories/',
      query: query.toQueryParameters(page: page),
      // Rides the catalog-version ETag: the quick-access strip re-fetches on
      // every POS open and categories almost never change.
      conditionalCache: true,
    );
    _session.ensureSuccess(
      response,
      'Product category request failed with status',
    );
    return ProductCategoryPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ProductCategory> createProductCategory(
    ProductCategoryDraft draft,
  ) async {
    final response = await _session.post(
      'product-categories/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Product category create failed with status',
    );
    return ProductCategory.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ProductCategory> updateProductCategory({
    required int id,
    required Map<String, Object?> changes,
  }) async {
    final response = await _session.patch(
      'product-categories/$id/',
      body: changes,
    );
    _session.ensureSuccess(
      response,
      'Product category update failed with status',
    );
    return ProductCategory.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteProductCategory(int id) async {
    final response = await _session.delete('product-categories/$id/');
    _session.ensureSuccess(
      response,
      'Product category delete failed with status',
    );
  }

  Future<VariantOptionValuePage> fetchVariantOptionValues({
    required ModelQuery query,
    int page = 1,
  }) async {
    final response = await _session.get(
      'variant-option-values/',
      query: query.toQueryParameters(page: page),
    );
    _session.ensureSuccess(
      response,
      'Variant option value request failed with status',
    );
    return VariantOptionValuePage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<VariantOptionValue> createVariantOptionValue(
    VariantOptionValueDraft draft,
  ) async {
    final response = await _session.post(
      'variant-option-values/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Variant option value create failed with status',
    );
    return VariantOptionValue.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<VariantOptionPage> fetchVariantOptions({
    required VariantOptionQuery query,
    int page = 1,
  }) async {
    final response = await _session.get(
      'variant-options/',
      query: query.toQueryParameters(page: page),
    );
    _session.ensureSuccess(
      response,
      'Variant option request failed with status',
    );
    return VariantOptionPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<VariantOption> createVariantOption(VariantOptionDraft draft) async {
    final response = await _session.post(
      'variant-options/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Variant option create failed with status',
    );
    return VariantOption.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
