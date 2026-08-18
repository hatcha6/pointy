import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/inventory_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/catalog_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_list.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// The products list always came back empty-handed the same way: "no products"
/// plus an "add a product" button, whether the shop was empty or the manager
/// had simply filtered it down to nothing. Creating a duplicate of a product
/// that was there all along is the failure mode this locks out.
void main() {
  testWidgets(
    'a filtered-to-nothing list explains itself and clears in one tap',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final requestedUrls = <Uri>[];
      final service = PosApiService(
        baseUrl: 'http://pointy.test/api',
        client: MockClient((request) async {
          requestedUrls.add(request.url);
          return http.Response(
            jsonEncode({'results': <Object?>[], 'next': null}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final viewModel = CatalogViewModel(CatalogRepository(service));
      addTearDown(viewModel.dispose);
      await viewModel.applyQuery(
        const ProductQuery(availability: ProductAvailabilityFilter.inactive),
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: PointyTheme.light(),
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
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
                      'display_name': 'مدير النظام',
                      'email': '',
                      'role': 'manager',
                      'permissions': <String>[],
                      'is_active': true,
                    }),
                  ),
                  onBarcodeSubmitted: (_) => false,
                  onOpenCameraScanner: () {},
                  onCreateProduct: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Scoped to the empty state: the action bar carries its own "add" button,
      // which stays available throughout.
      final emptyStateCreateButton = find.descendant(
        of: find.byType(PointyEmptyState),
        matching: find.text('إضافة منتج'),
      );

      expect(
        find.text('لا توجد منتجات مطابقة للفلاتر المحددة'),
        findsOneWidget,
      );
      expect(emptyStateCreateButton, findsNothing);

      await tester.tap(find.text('مسح البحث والفلاتر'));
      await tester.pumpAndSettle();

      expect(viewModel.query.availability, ProductAvailabilityFilter.all);
      expect(
        requestedUrls.last.queryParameters.containsKey('is_active'),
        isFalse,
      );
      expect(emptyStateCreateButton, findsOneWidget);
    },
  );
}
