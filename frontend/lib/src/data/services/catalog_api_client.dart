import '../models/attachment_summary.dart';
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

  Future<Product> createProduct(ProductDraft draft) async {
    final response = await _session.post('products/', body: draft.toJson());
    _session.ensureSuccess(response, 'Product create failed with status');
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
    _session.ensureSuccess(response, 'Product update failed with status');
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
    );
    _session.ensureSuccess(
      response,
      'Product variant request failed with status',
    );
    return ProductVariantPage.fromJson(
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
    _session.ensureSuccess(
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
    _session.ensureSuccess(
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
    _session.ensureSuccess(
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
