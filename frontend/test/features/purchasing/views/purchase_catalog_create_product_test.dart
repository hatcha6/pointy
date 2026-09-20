import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_form.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_catalog_pane.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// A delivery routinely carries something the catalog has never seen. Until
/// this button the only way in was to scan a code — and a sack of rice off a
/// wholesaler's truck has no barcode at all, which left the buyer abandoning
/// the order to go and create the product in the catalog screen.
void main() {
  const createProductButton = ValueKey('purchase_create_product_button');

  AuthorizationCapabilities capabilitiesFor(String role) {
    return AuthorizationCapabilities.forUser(
      PosUser.fromJson({
        'id': 1,
        'username': role,
        'display_name': role,
        'email': '',
        'role': role,
        'permissions': <String>[],
        'is_active': true,
      }),
    );
  }

  Future<PurchaseViewModel> pumpPane(
    WidgetTester tester, {
    required AuthorizationCapabilities capabilities,
  }) async {
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
              capabilities: capabilities,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return viewModel;
  }

  testWidgets('the purchase catalog offers the product-creation wizard', (
    tester,
  ) async {
    await pumpPane(tester, capabilities: capabilitiesFor('manager'));

    expect(find.byKey(createProductButton), findsOneWidget);

    await tester.tap(find.byKey(createProductButton));
    await tester.pumpAndSettle();

    // The same wizard the catalog screen uses, opened with nothing scanned.
    expect(find.byType(ProductForm), findsOneWidget);
  });

  testWidgets('a buyer who cannot create products is not offered the button', (
    tester,
  ) async {
    await pumpPane(tester, capabilities: capabilitiesFor('cashier'));

    expect(find.byKey(createProductButton), findsNothing);
  });
}
