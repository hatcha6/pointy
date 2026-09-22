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

/// Whether products a *feature* owns — today the one service product per
/// recharge provider — are included. They exist so a top-up has an order line
/// to be, are priced per line from the provider's quote, and so carry a
/// standing price of zero; a till that showed one offered a free recharge.
/// Hidden everywhere by default, and only the back-office catalog opts in via
/// [includeSystem] so an owner can still rename one and see what it earned.
enum ProductSystemFilter implements QueryFilterSet {
  excludeSystem(null),
  includeSystem(QueryFilter(parameter: 'system', value: 'all'));

  const ProductSystemFilter(this._filter);

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
    this.system = ProductSystemFilter.excludeSystem,
    this.supplierId,
    this.supplierName,
    this.preferredSupplierId,
    this.warehouseId,
    this.ordering = ProductOrdering.name,
  });

  @override
  final String search;
  final String barcode;
  final List<ProductCategory> categories;
  final ProductAvailabilityFilter availability;
  final ProductArchivedFilter archived;
  final ProductStockFilter stock;
  final ProductSystemFilter system;
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

  /// Narrow every stock figure to one place.
  ///
  /// Null means the whole shop, which is the question a catalog normally
  /// answers and the only one a single-place shop can ask. With a store room,
  /// "what is on the shop floor" is the same list with its sums narrowed — not
  /// a different screen that could drift from this one.
  final int? warehouseId;
  @override
  final ProductOrdering ordering;

  @override
  Iterable<QueryFilter> get filters => [
    ...availability.filters,
    ...archived.filters,
    ...stock.filters,
    ...system.filters,
    if (barcode.trim().isNotEmpty)
      QueryFilter(parameter: 'barcode', value: barcode.trim()),
    if (categories.isNotEmpty)
      QueryFilter(
        parameter: 'category',
        value: categories.map((category) => category.id).join(','),
      ),
    if (supplierId != null)
      QueryFilter(parameter: 'supplier', value: '$supplierId'),
    if (warehouseId != null)
      QueryFilter(parameter: 'warehouse', value: '$warehouseId'),
    if (preferredSupplierId != null)
      QueryFilter(
        parameter: 'preferred_supplier',
        value: '$preferredSupplierId',
      ),
  ];

  ProductQuery copyWith({
    String? search,
    String? barcode,
    List<ProductCategory>? categories,
    ProductAvailabilityFilter? availability,
    ProductArchivedFilter? archived,
    ProductStockFilter? stock,
    ProductSystemFilter? system,
    ProductOrdering? ordering,
  }) {
    return ProductQuery(
      search: search ?? this.search,
      barcode: barcode ?? this.barcode,
      categories: categories ?? this.categories,
      availability: availability ?? this.availability,
      archived: archived ?? this.archived,
      stock: stock ?? this.stock,
      system: system ?? this.system,
      supplierId: supplierId,
      warehouseId: warehouseId,
      supplierName: supplierName,
      preferredSupplierId: preferredSupplierId,
      ordering: ordering ?? this.ordering,
    );
  }

  /// Set or clear the place filter. Passing null means the whole shop, which
  /// [copyWith] cannot express because it preserves the current value.
  ProductQuery withWarehouse(int? warehouseId) {
    return ProductQuery(
      search: search,
      barcode: barcode,
      categories: categories,
      availability: availability,
      archived: archived,
      stock: stock,
      system: system,
      supplierId: supplierId,
      warehouseId: warehouseId,
      supplierName: supplierName,
      preferredSupplierId: preferredSupplierId,
      ordering: ordering,
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
      system: system,
      supplierId: supplierId,
      warehouseId: warehouseId,
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
      system: system,
      supplierId: supplierId,
      warehouseId: warehouseId,
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
        other.system == system &&
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
    system,
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
