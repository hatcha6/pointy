import '../models/product.dart';
import '../models/product_category.dart';
import '../models/product_page.dart';
import '../models/query.dart';
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

  Future<Product> createProduct(ProductDraft draft) async {
    final response = await _session.post('products/', body: draft.toJson());
    _session.ensureSuccess(response, 'Product create failed with status');
    return Product.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
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
}
