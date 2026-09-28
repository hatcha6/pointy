import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/inventory_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/catalog_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_list.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/query_controls/query_filter_button.dart';

/// The catalog opens on "most bought", as the till does. That is its own
/// starting sort, not a filter, so the filter button counts the sort only
/// once it moves.
void main() {
  testWidgets('a fresh catalog counts its sort only once it moves', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({'results': <Object?>[], 'next': null}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    final viewModel = CatalogViewModel(CatalogRepository(service));
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: viewModel,
            builder: (context, _) => ProductList(
              viewModel: viewModel,
              inventoryRepository: InventoryRepository(service),
              printingRepository: PrintingRepository(service),
              purchaseRepository: PurchaseRepository(service),
              saleRepository: SaleRepository(service),
              shopSettingsRepository: ShopSettingsRepository(service),
              capabilities: AuthorizationCapabilities.forUser(
                PosUser.fromJson(const {
                  'id': 1,
                  'username': 'manager',
                  'role': 'manager',
                  'permissions': <String>[],
                }),
              ),
              onBarcodeSubmitted: (_) => false,
              onOpenCameraScanner: () {},
              onCreateProduct: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(viewModel.query.ordering, ProductOrdering.mostBought);
    expect(_filterCount(tester), 0);

    await viewModel.applyQuery(
      viewModel.query.copyWith(ordering: ProductOrdering.name),
    );
    await tester.pumpAndSettle();

    expect(_filterCount(tester), 1);
  });
}

int _filterCount(WidgetTester tester) => tester
    .widget<QueryFilterButton>(find.byType(QueryFilterButton))
    .activeCount;
