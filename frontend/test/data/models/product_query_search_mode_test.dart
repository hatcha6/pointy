import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';

/// [ProductSearchMode] is what the search-mode picker sets on a product query;
/// the server reads it as `?search_in=`.
void main() {
  test('a narrowed search asks the server for that half only', () {
    const byName = ProductQuery(
      search: 'بيبسي 330',
      searchMode: ProductSearchMode.name,
    );
    const byCode = ProductQuery(
      search: '330',
      searchMode: ProductSearchMode.code,
    );

    expect(byName.toQueryParameters(page: 1)['search_in'], 'name');
    expect(byCode.toQueryParameters(page: 1)['search_in'], 'code');
  });

  test('the ordinary search sends no scope at all', () {
    const query = ProductQuery(search: 'بيبسي');

    expect(query.toQueryParameters(page: 1), isNot(contains('search_in')));
  });

  test('browsing without a term is one request whatever the mode', () {
    // Otherwise every page of the catalog would be cached three times over.
    for (final mode in ProductSearchMode.values) {
      expect(
        ProductQuery(searchMode: mode).toQueryParameters(page: 1),
        const ProductQuery().toQueryParameters(page: 1),
      );
    }
    expect(
      const ProductQuery(
        search: '   ',
        searchMode: ProductSearchMode.code,
      ).toQueryParameters(page: 1),
      isNot(contains('search_in')),
    );
  });

  test('the mode survives every way a screen reshapes its query', () {
    const query = ProductQuery(
      search: 'x',
      supplierId: 4,
      searchMode: ProductSearchMode.code,
    );

    expect(query.copyWith(search: 'y').searchMode, ProductSearchMode.code);
    expect(query.withSupplier().searchMode, ProductSearchMode.code);
    expect(query.withPreferredSupplier(9).searchMode, ProductSearchMode.code);
    expect(query.withWarehouse(2).searchMode, ProductSearchMode.code);
    expect(
      query.copyWith(searchMode: ProductSearchMode.all).searchMode,
      ProductSearchMode.all,
    );
  });

  test('queries that differ only by mode are different queries', () {
    // The till and purchasing skip a reload when the new query equals the
    // old one; switching the picker must not look like "nothing changed".
    const byName = ProductQuery(
      search: 'x',
      searchMode: ProductSearchMode.name,
    );

    expect(byName == const ProductQuery(search: 'x'), isFalse);
    expect(
      byName ==
          const ProductQuery(search: 'x', searchMode: ProductSearchMode.name),
      isTrue,
    );
    expect(
      byName.hashCode,
      const ProductQuery(
        search: 'x',
        searchMode: ProductSearchMode.name,
      ).hashCode,
    );
  });
}
