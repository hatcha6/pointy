import 'dart:async';
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

/// «منتج مشابه» on a product's details: offered to whoever may create
/// products, never for a product a feature owns, and only once the product
/// has loaded in full — a copy of the list row it opened on would quietly
/// lack its units and options.
void main() {
  const similarButton = ValueKey('product_details_similar_button');
  const productJson = <String, Object?>{
    'id': 7,
    'name': 'شاي أخضر',
    'description': 'أوراق كاملة',
    'unit': 'piece',
    'quantity_on_hand': 6,
    'default_variant': {
      'id': 71,
      'product': 7,
      'sku': '1007',
      'unit_price': '10.00',
      'is_default': true,
    },
  };

  AuthorizationCapabilities capabilitiesOf(
    String role, [
    List<String> permissions = const [],
  ]) {
    return AuthorizationCapabilities.forUser(
      PosUser.fromJson({
        'id': 1,
        'username': role,
        'display_name': role,
        'email': '',
        'role': role,
        'permissions': permissions,
        'is_active': true,
      }),
    );
  }

  Future<void> pumpDetails(
    WidgetTester tester, {
    Map<String, Object?> json = productJson,
    Future<void>? loaded,
    AuthorizationCapabilities? capabilities,
    ValueChanged<Product>? onCreateSimilar,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        final isProduct = request.url.path.endsWith('/products/7/');
        if (isProduct) {
          await loaded;
        }
        return http.Response(
          jsonEncode(
            isProduct ? json : const {'results': <Object?>[], 'next': null},
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final viewModel = ProductDetailsViewModel(
      CatalogRepository(service),
      PurchaseRepository(service),
      SaleRepository(service),
      // What a list row hands over: a name, not the whole product.
      const Product(id: 7, name: 'شاي أخضر', quantityOnHand: 6),
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
            capabilities: capabilities ?? capabilitiesOf('manager'),
            onCreateSimilar: onCreateSimilar,
          ),
        ),
      ),
    );
  }

  bool enabled(WidgetTester tester) =>
      tester.widget<ButtonStyleButton>(find.byKey(similarButton)).enabled;

  testWidgets('it hands over the product as loaded, once it has loaded', (
    tester,
  ) async {
    final loaded = Completer<void>();
    final copied = <Product>[];
    await pumpDetails(
      tester,
      loaded: loaded.future,
      onCreateSimilar: copied.add,
    );
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.similarProductAction), findsOne);
    expect(enabled(tester), isFalse, reason: 'still the list row');

    loaded.complete();
    await tester.pumpAndSettle();
    expect(enabled(tester), isTrue);

    await tester.ensureVisible(find.byKey(similarButton));
    await tester.tap(find.byKey(similarButton));
    expect(copied.single.description, 'أوراق كاملة');
  });

  testWidgets('it is not offered where no product can be created from it', (
    tester,
  ) async {
    // No catalog behind these details to create one with.
    await pumpDetails(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(similarButton), findsNothing);

    // Somebody who may change products but not create them.
    await pumpDetails(
      tester,
      capabilities: capabilitiesOf('cashier', ['catalog.change_product']),
      onCreateSimilar: (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.byKey(similarButton), findsNothing);

    // A product a feature owns: a copy would pass for it without the
    // feature behind it.
    await pumpDetails(
      tester,
      json: {...productJson, 'is_system': true, 'system_kind': 'service'},
      onCreateSimilar: (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.byKey(similarButton), findsNothing);
  });
}
