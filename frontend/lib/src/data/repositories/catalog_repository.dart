import '../../core/result.dart';
import '../models/product.dart';
import '../services/pos_api_service.dart';

class CatalogRepository {
  CatalogRepository(this._service);

  final PosApiService _service;

  Future<Result<List<Product>>> loadProducts() async {
    try {
      return Ok(await _service.fetchProducts());
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  List<Product> sampleProducts() {
    return const [
      Product(
        id: 1,
        sku: 'COF-001',
        name: 'House Coffee',
        unitPrice: 3.50,
        taxRate: 0.08,
      ),
      Product(
        id: 2,
        sku: 'TEA-001',
        name: 'Mint Tea',
        unitPrice: 2.75,
        taxRate: 0.08,
      ),
      Product(
        id: 3,
        sku: 'SNK-012',
        name: 'Date Bar',
        unitPrice: 1.95,
        taxRate: 0.08,
      ),
      Product(
        id: 4,
        sku: 'BKR-044',
        name: 'Zaatar Croissant',
        unitPrice: 4.25,
        taxRate: 0.08,
      ),
      Product(
        id: 5,
        sku: 'JCE-002',
        name: 'Orange Juice',
        unitPrice: 3.25,
        taxRate: 0.08,
      ),
      Product(
        id: 6,
        sku: 'SND-019',
        name: 'Halloumi Sandwich',
        unitPrice: 6.80,
        taxRate: 0.08,
      ),
    ];
  }
}
