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
    return Result.guard(() => _service.fetchProducts(query: query, page: page));
  }

  Future<Result<Product>> createProduct(ProductDraft draft) async {
    return Result.guard(() => _service.createProduct(draft));
  }

  Future<Result<Product?>> findProductByBarcode(
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
      final page = await _service.fetchProducts(query: query, page: 1);
      for (final product in page.products) {
        if (product.barcode.trim() == normalizedBarcode) {
          return product;
        }
      }
      return null;
    });
  }

  List<Product> sampleProducts(ProductQuery query) {
    final products = const [
      Product(
        id: 1,
        sku: 'COF-001',
        name: 'قهوة البيت',
        unitPrice: 3.50,
        barcode: '1000001',
        quantityOnHand: 12,
      ),
      Product(
        id: 2,
        sku: 'TEA-001',
        name: 'شاي بالنعناع',
        unitPrice: 2.75,
        barcode: '1000002',
        quantityOnHand: 12,
      ),
      Product(
        id: 3,
        sku: 'SNK-012',
        name: 'لوح تمر',
        unitPrice: 1.95,
        barcode: '1000003',
        quantityOnHand: 12,
      ),
      Product(
        id: 4,
        sku: 'BKR-044',
        name: 'كرواسون زعتر',
        unitPrice: 4.25,
        barcode: '1000004',
        quantityOnHand: 12,
      ),
      Product(
        id: 5,
        sku: 'JCE-002',
        name: 'عصير برتقال',
        unitPrice: 3.25,
        barcode: '1000005',
        quantityOnHand: 12,
      ),
      Product(
        id: 6,
        sku: 'SND-019',
        name: 'ساندويتش حلومي',
        unitPrice: 6.80,
        barcode: '1000006',
        quantityOnHand: 12,
      ),
    ];

    final search = query.search.trim().toLowerCase();
    final barcode = query.barcode.trim();
    final filtered = search.isEmpty && barcode.isEmpty
        ? products
        : products
              .where((product) {
                final matchesSearch =
                    search.isEmpty ||
                    product.name.toLowerCase().contains(search) ||
                    product.sku.toLowerCase().contains(search) ||
                    product.barcode.toLowerCase().contains(search);
                final matchesBarcode =
                    barcode.isEmpty || product.barcode == barcode;
                return matchesSearch && matchesBarcode;
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
