import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_catalog_pane.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/query_controls/query_filter_button.dart';

import '../../../support/key_value_store_testing.dart';

/// The till opens on "most bought". That is where it starts, not a filter the
/// cashier set, so the filter button carries no count until the cashier moves
/// something — and a fresh till used to show "1".
void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));

  testWidgets('a fresh till shows no filter count', (tester) async {
    final viewModel = _freshTill();
    addTearDown(viewModel.dispose);

    await _pumpCatalog(tester, viewModel);

    expect(viewModel.query.ordering, ProductOrdering.mostBought);
    expect(_filterCount(tester), isNull);
  });

  testWidgets('a changed sort counts as one filter until reset', (
    tester,
  ) async {
    final viewModel = _freshTill();
    addTearDown(viewModel.dispose);
    await _pumpCatalog(tester, viewModel);

    await _openFilters(tester);
    await tester.tap(find.text(l10n.orderingPriceAsc));
    await tester.pump();
    await tester.tap(find.text(l10n.applyFiltersButton));
    await tester.pumpAndSettle();

    expect(viewModel.query.ordering, ProductOrdering.priceAsc);
    expect(_filterCount(tester), '1');

    // Reset returns to the till's own sort, not to A–Z, and the count goes.
    await _openFilters(tester);
    await tester.tap(find.text(l10n.resetFiltersButton));
    await tester.pump();
    await tester.tap(find.text(l10n.applyFiltersButton));
    await tester.pumpAndSettle();

    expect(viewModel.query.ordering, ProductOrdering.mostBought);
    expect(_filterCount(tester), isNull);
  });
}

/// The number on the filter button, or null while it shows none.
String? _filterCount(WidgetTester tester) {
  final badge = find.descendant(
    of: find.byType(QueryFilterButton),
    matching: find.byType(Visibility),
  );
  if (!tester.widget<Visibility>(badge).visible) {
    return null;
  }
  return tester
      .widget<Text>(find.descendant(of: badge, matching: find.byType(Text)))
      .data;
}

Future<void> _openFilters(WidgetTester tester) async {
  await tester.tap(find.byType(QueryFilterButton));
  await tester.pumpAndSettle();
}

PosViewModel _freshTill() {
  installMemoryKeyValueStore();
  return PosViewModel(
    _FakeCatalogRepository(),
    RegisterSessionRepository(PosApiService()),
    SaleRepository(PosApiService()),
    ShopSettingsRepository(PosApiService()),
    PrintingRepository(PosApiService()),
    sessionStorage: MemoryScopedJsonStorage(),
  );
}

Future<void> _pumpCatalog(WidgetTester tester, PosViewModel viewModel) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: viewModel,
          builder: (context, _) =>
              PosCatalogPane(viewModel: viewModel, capabilities: _cashierCaps),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final AuthorizationCapabilities _cashierCaps =
    AuthorizationCapabilities.forUser(
      PosUser.fromJson(const {
        'id': 1,
        'username': 'cashier',
        'role': 'cashier',
        'permissions': <String>[],
      }),
    );

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());

  @override
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
    bool bypassCache = false,
  }) async => const Ok(ProductPage(products: [], hasMore: false));

  @override
  Future<Result<List<ProductCategory>>> loadQuickAccessCategories() async =>
      const Ok([]);
}
