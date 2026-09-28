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
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_catalog_pane.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// Purchasing pins its catalog to active products, as the till does. An empty
/// catalog with nothing typed is simply empty; it used to say "no products
/// match the selected filters" and offer to clear filters the buyer never set.
void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));

  testWidgets('a purchase catalog with nothing typed says so plainly', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        return http.Response(
          jsonEncode(const {'results': <Object?>[], 'next': null}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final viewModel = PurchaseViewModel(
      CatalogRepository(service),
      PurchaseRepository(service),
    );
    addTearDown(viewModel.dispose);
    await viewModel.loadCatalog();

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: viewModel,
            builder: (context, _) => PurchaseCatalogPane(
              viewModel: viewModel,
              capabilities: AuthorizationCapabilities.forUser(
                PosUser.fromJson(const {
                  'id': 1,
                  'username': 'manager',
                  'display_name': 'manager',
                  'email': '',
                  'role': 'manager',
                  'permissions': <String>[],
                  'is_active': true,
                }),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(viewModel.query.availability, ProductAvailabilityFilter.active);
    expect(find.text(l10n.emptyCatalog), findsOneWidget);
    expect(find.text(l10n.catalogNoFilteredResultsTitle), findsNothing);
    expect(find.text(l10n.catalogClearSearchAndFiltersButton), findsNothing);
  });
}
