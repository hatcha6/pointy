import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/inventory_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/product_details_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// The variants table sat inside a horizontal scroll view, which hands its
/// child unbounded width — so the table sized itself to its columns and left
/// a dead strip down the side of the card on any wide screen. It now fills
/// the section and only scrolls sideways when the columns genuinely overflow.
void main() {
  const productJson = <String, Object?>{
    'id': 7,
    'name': 'شاي أخضر',
    'unit': 'piece',
    'quantity_on_hand': 6,
    'variants': [
      {
        'id': 71,
        'product': 7,
        'sku': 'T-S',
        'unit_price': '10.00',
        'name': 'صغير',
        'quantity_on_hand': 2,
      },
      {
        'id': 72,
        'product': 7,
        'sku': 'T-L',
        'unit_price': '12.00',
        'name': 'كبير',
        'quantity_on_hand': 4,
      },
    ],
  };

  testWidgets('the variants table fills the width of its section', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        // The details view model re-asks the server for the product it was
        // handed, so the variants must come back from here too.
        final body = request.url.path.endsWith('/products/7/')
            ? productJson
            : const {'results': <Object?>[], 'next': null};
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final viewModel = ProductDetailsViewModel(
      CatalogRepository(service),
      PurchaseRepository(service),
      SaleRepository(service),
      Product.fromJson(productJson),
      shouldLoadSaleHistory: false,
      shouldLoadPurchaseHistory: false,
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Scaffold(
          body: ProductDetailsView(
            viewModel: viewModel,
            inventoryRepository: InventoryRepository(service),
            printingRepository: PrintingRepository(service),
            purchaseRepository: PurchaseRepository(service),
            shopSettingsRepository: ShopSettingsRepository(service),
            capabilities: AuthorizationCapabilities.forUser(
              PosUser.fromJson(const {
                'id': 1,
                'username': 'manager',
                'display_name': 'مدير النظام',
                'email': '',
                'role': 'manager',
                'permissions': <String>[],
                'is_active': true,
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = find.byType(DataTable);
    expect(table, findsOneWidget);

    // The scroll viewport around the table is the width the table is allowed
    // to use; the table must occupy all of it rather than hugging its columns.
    final viewport = find
        .ancestor(of: table, matching: find.byType(SingleChildScrollView))
        .first;
    expect(tester.getSize(table).width, tester.getSize(viewport).width);
  });
}
