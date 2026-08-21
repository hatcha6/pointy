import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bought_together_product.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/product_details_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_parent_edit_sheet.dart';

/// The parent-product editor sits on its own route and holds a page of edits
/// (name, categories, units, modifiers, image). Its sibling in the same file —
/// [ProductVariantFormSheet] — has always warned before discarding them; this
/// one silently threw the whole page away on a back press.
void main() {
  Product buildProduct() => const Product(
    id: 1,
    name: 'شاي',
    quantityOnHand: 0,
    variants: [
      ProductVariant(id: 11, productId: 1, sku: 'TEA-1', unitPrice: 5),
    ],
  );

  PosApiService buildService() => PosApiService(
    baseUrl: 'http://pointy.test/api',
    client: MockClient((request) async {
      return http.Response(
        jsonEncode(const {'results': <Object?>[], 'next': null}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );

  /// Pushes the sheet on its own route, the way `showProductParentEditor`
  /// presents it, so a back attempt reaches its `PopScope`.
  Future<GlobalKey<NavigatorState>> pushSheet(WidgetTester tester) async {
    final service = buildService();
    final viewModel = ProductDetailsViewModel(
      _StubCatalogRepository(service, buildProduct()),
      _StubPurchaseRepository(service),
      _StubSaleRepository(service),
      buildProduct(),
      shouldLoadSaleHistory: false,
      shouldLoadPurchaseHistory: false,
    );
    addTearDown(viewModel.dispose);

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              Scaffold(body: ProductParentEditSheet(viewModel: viewModel)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return navigatorKey;
  }

  testWidgets('leaving with an edited field asks before discarding', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final navigatorKey = await pushSheet(tester);

    await tester.enterText(find.byType(TextFormField).first, 'شاي أخضر');
    await tester.pumpAndSettle();

    navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();

    expect(find.text(l10n.unsavedChangesTitle), findsOneWidget);
    // Keep editing leaves the user exactly where they were, edit intact.
    await tester.tap(find.text(l10n.keepEditingButton));
    await tester.pumpAndSettle();
    expect(find.byType(ProductParentEditSheet), findsOneWidget);
    expect(find.text('شاي أخضر'), findsOneWidget);
  });

  testWidgets('discarding confirms out of the editor', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final navigatorKey = await pushSheet(tester);

    await tester.enterText(find.byType(TextFormField).first, 'شاي أخضر');
    await tester.pumpAndSettle();

    navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.discardChangesButton));
    await tester.pumpAndSettle();

    expect(find.byType(ProductParentEditSheet), findsNothing);
  });

  testWidgets('an untouched editor leaves without a prompt', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final navigatorKey = await pushSheet(tester);

    // No edit at all — including after the async option/unit loaders have
    // settled, which must not make the sheet look dirty on their own.
    navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();

    expect(find.text(l10n.unsavedChangesTitle), findsNothing);
    expect(find.byType(ProductParentEditSheet), findsNothing);
  });

  testWidgets('a toggled switch counts as an edit, not just typed text', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final navigatorKey = await pushSheet(tester);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();

    expect(find.text(l10n.unsavedChangesTitle), findsOneWidget);
  });
}

class _StubCatalogRepository extends CatalogRepository {
  _StubCatalogRepository(super.service, this._product);

  final Product _product;

  @override
  Future<Result<Product>> loadProduct(int id) async => Ok(_product);

  @override
  Future<Result<List<BoughtTogetherProduct>>> loadBoughtTogether(
    int productId, {
    int limit = 8,
  }) async => const Ok([]);
}

class _StubPurchaseRepository extends PurchaseRepository {
  _StubPurchaseRepository(super.service);

  @override
  Future<Result<List<VariantCostSummary>>> loadProductCostSummary(
    int productId,
  ) async => const Ok([]);
}

class _StubSaleRepository extends SaleRepository {
  _StubSaleRepository(super.service);
}
