import '../../core/result.dart';
import '../models/product.dart';
import '../models/product_page.dart';
import '../models/product_query.dart';
import '../services/pos_api_service.dart';

class CatalogRepository {
  CatalogRepository(this._service);

  final PosApiService _service;

  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
  }) async {
    try {
      return Ok(await _service.fetchProducts(query: query, page: page));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<Product>> createProduct(ProductDraft draft) async {
    try {
      return Ok(await _service.createProduct(draft));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  List<Product> sampleProducts(ProductQuery query) {
    final products = const [
      Product(
        id: 1,
        sku: 'COF-001',
        name: 'قهوة البيت',
        unitPrice: 3.50,
        quantityOnHand: 12,
      ),
      Product(
        id: 2,
        sku: 'TEA-001',
        name: 'شاي بالنعناع',
        unitPrice: 2.75,
        quantityOnHand: 12,
      ),
      Product(
        id: 3,
        sku: 'SNK-012',
        name: 'لوح تمر',
        unitPrice: 1.95,
        quantityOnHand: 12,
      ),
      Product(
        id: 4,
        sku: 'BKR-044',
        name: 'كرواسون زعتر',
        unitPrice: 4.25,
        quantityOnHand: 12,
      ),
      Product(
        id: 5,
        sku: 'JCE-002',
        name: 'عصير برتقال',
        unitPrice: 3.25,
        quantityOnHand: 12,
      ),
      Product(
        id: 6,
        sku: 'SND-019',
        name: 'ساندويتش حلومي',
        unitPrice: 6.80,
        quantityOnHand: 12,
      ),
    ];

    final search = query.search.trim().toLowerCase();
    final filtered = search.isEmpty
        ? products
        : products
              .where((product) {
                return product.name.toLowerCase().contains(search) ||
                    product.sku.toLowerCase().contains(search) ||
                    product.barcode.toLowerCase().contains(search);
              })
              .toList(growable: false);

    final sorted = [...filtered];
    sorted.sort((a, b) {
      return switch (query.ordering) {
        ProductOrdering.name => a.name.compareTo(b.name),
        ProductOrdering.priceAsc => a.unitPrice.compareTo(b.unitPrice),
        ProductOrdering.priceDesc => b.unitPrice.compareTo(a.unitPrice),
        ProductOrdering.newest => b.id.compareTo(a.id),
      };
    });
    return sorted;
  }
}
