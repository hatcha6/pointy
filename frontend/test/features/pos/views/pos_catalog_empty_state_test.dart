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

import '../../../support/key_value_store_testing.dart';

/// The till pins its catalog to active products itself. That is where it
/// starts, not a filter the cashier set, so an empty catalog used to claim
/// "no products match the selected filters" and offer to clear filters nobody
/// set — a button that did nothing, since the till puts "active" straight back.
void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));

  testWidgets('an empty till with nothing typed says so plainly', (
    tester,
  ) async {
    final viewModel = _till();
    addTearDown(viewModel.dispose);
    await viewModel.loadCatalog();

    await _pumpCatalog(tester, viewModel);

    expect(viewModel.query.availability, ProductAvailabilityFilter.active);
    expect(find.text(l10n.emptyCatalog), findsOneWidget);
    expect(find.text(l10n.catalogNoFilteredResultsTitle), findsNothing);
    expect(find.text(l10n.catalogClearSearchAndFiltersButton), findsNothing);
  });

  testWidgets('a search that finds nothing still offers to clear it', (
    tester,
  ) async {
    final viewModel = _till();
    addTearDown(viewModel.dispose);
    await viewModel.updateSearch('شيبس');

    await _pumpCatalog(tester, viewModel);

    expect(find.text(l10n.catalogNoSearchResultsTitle('شيبس')), findsOneWidget);

    await tester.tap(find.text(l10n.catalogClearSearchAndFiltersButton));
    await tester.pumpAndSettle();

    expect(viewModel.query.search, isEmpty);
    expect(viewModel.query.availability, ProductAvailabilityFilter.active);
    expect(find.text(l10n.emptyCatalog), findsOneWidget);
    expect(find.text(l10n.catalogClearSearchAndFiltersButton), findsNothing);
  });
}

PosViewModel _till() {
  installMemoryKeyValueStore();
  return PosViewModel(
    _EmptyCatalogRepository(),
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

class _EmptyCatalogRepository extends CatalogRepository {
  _EmptyCatalogRepository() : super(PosApiService());

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
