import 'query.dart';
import 'product_category.dart';

enum ProductAvailabilityFilter implements QueryFilterSet {
  all(null),
  active(QueryFilter(parameter: 'is_active', value: 'true')),
  inactive(QueryFilter(parameter: 'is_active', value: 'false'));

  const ProductAvailabilityFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

/// Whether archived (retired) products are included in a product listing.
/// Archived products are hidden everywhere by default; only the dedicated
/// "Archived" catalog view opts in via [onlyArchived].
enum ProductArchivedFilter implements QueryFilterSet {
  excludeArchived(null),
  onlyArchived(QueryFilter(parameter: 'archived', value: 'true'));

  const ProductArchivedFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

/// Whether out-of-stock products are included. The POS opts into
/// [inStockOnly] when overselling is disabled so cashiers never see (or sell)
/// products that have run out; service and made-to-order products are kept
/// server-side because they carry no stock of their own.
enum ProductStockFilter implements QueryFilterSet {
  all(null),
  inStockOnly(QueryFilter(parameter: 'in_stock', value: 'true'));

  const ProductStockFilter(this._filter);

  final QueryFilter? _filter;

  @override
  Iterable<QueryFilter> get filters {
    final filter = _filter;
    return filter == null ? const [] : [filter];
  }
}

enum ProductOrdering implements QueryOrdering {
  name('name'),
  // "Most bought": sorts by the server's denormalized popularity score (highest
  // first). The default for POS/catalog browsing so fast-movers surface first.
  mostBought('-popularity'),
  priceAsc('unit_price'),
  priceDesc('-unit_price'),
  newest('-created_at');

  const ProductOrdering(this.apiValue);

  @override
  final String apiValue;
}

class ProductQuery extends ModelQuery {
  const ProductQuery({
    this.search = '',
    this.barcode = '',
    this.categories = const [],
    this.availability = ProductAvailabilityFilter.all,
    this.archived = ProductArchivedFilter.excludeArchived,
    this.stock = ProductStockFilter.all,
    this.supplierId,
    this.supplierName,
    this.preferredSupplierId,
    this.ordering = ProductOrdering.name,
  });

  @override
  final String search;
  final String barcode;
  final List<ProductCategory> categories;
  final ProductAvailabilityFilter availability;
  final ProductArchivedFilter archived;
  final ProductStockFilter stock;
  // Filter to products a given supplier has supplied (resolved server-side
  // through that supplier's purchase orders). [supplierName] is carried only so
  // the active-filter chip can label the selection.
  final int? supplierId;
  final String? supplierName;
  // Soft supplier boost (purchasing PO catalog): unlike [supplierId] this does
  // NOT filter — it floats that supplier's products to the top while keeping the
  // rest searchable, so a buyer can still add a product the supplier hasn't
  // stocked before. Maps to the server's ?preferred_supplier=.
  final int? preferredSupplierId;
  @override
  final ProductOrdering ordering;

  @override
  Iterable<QueryFilter> get filters => [
    ...availability.filters,
    ...archived.filters,
    ...stock.filters,
    if (barcode.trim().isNotEmpty)
      QueryFilter(parameter: 'barcode', value: barcode.trim()),
    if (categories.isNotEmpty)
      QueryFilter(
        parameter: 'category',
        value: categories.map((category) => category.id).join(','),
      ),
    if (supplierId != null)
      QueryFilter(parameter: 'supplier', value: '$supplierId'),
    if (preferredSupplierId != null)
      QueryFilter(parameter: 'preferred_supplier', value: '$preferredSupplierId'),
  ];

  ProductQuery copyWith({
    String? search,
    String? barcode,
    List<ProductCategory>? categories,
    ProductAvailabilityFilter? availability,
    ProductArchivedFilter? archived,
    ProductStockFilter? stock,
    ProductOrdering? ordering,
  }) {
    return ProductQuery(
      search: search ?? this.search,
      barcode: barcode ?? this.barcode,
      categories: categories ?? this.categories,
      availability: availability ?? this.availability,
      archived: archived ?? this.archived,
      stock: stock ?? this.stock,
      supplierId: supplierId,
      supplierName: supplierName,
      preferredSupplierId: preferredSupplierId,
      ordering: ordering ?? this.ordering,
    );
  }

  /// Set or clear the supplier filter. Passing null clears it (which [copyWith]
  /// can't express, since it preserves the current value).
  ProductQuery withSupplier({int? supplierId, String? supplierName}) {
    return ProductQuery(
      search: search,
      barcode: barcode,
      categories: categories,
      availability: availability,
      archived: archived,
      stock: stock,
      supplierId: supplierId,
      supplierName: supplierName,
      preferredSupplierId: preferredSupplierId,
      ordering: ordering,
    );
  }

  /// Set or clear the soft supplier boost (purchasing PO catalog). Passing null
  /// clears it (which [copyWith] can't express, since it preserves the value).
  ProductQuery withPreferredSupplier(int? preferredSupplierId) {
    return ProductQuery(
      search: search,
      barcode: barcode,
      categories: categories,
      availability: availability,
      archived: archived,
      stock: stock,
      supplierId: supplierId,
      supplierName: supplierName,
      preferredSupplierId: preferredSupplierId,
      ordering: ordering,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ProductQuery &&
        other.search == search &&
        other.barcode == barcode &&
        _sameCategoryIds(other.categories, categories) &&
        other.availability == availability &&
        other.archived == archived &&
        other.stock == stock &&
        other.supplierId == supplierId &&
        other.preferredSupplierId == preferredSupplierId &&
        other.ordering == ordering;
  }

  @override
  int get hashCode => Object.hash(
    search,
    barcode,
    Object.hashAll(categories.map((category) => category.id)),
    availability,
    archived,
    stock,
    supplierId,
    preferredSupplierId,
    ordering,
  );

  static bool _sameCategoryIds(
    List<ProductCategory> first,
    List<ProductCategory> second,
  ) {
    if (first.length != second.length) {
      return false;
    }
    for (var index = 0; index < first.length; index += 1) {
      if (first[index].id != second[index].id) {
        return false;
      }
    }
    return true;
  }
}
