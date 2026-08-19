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
import 'package:pointy_frontend/src/features/catalog/views/product_variant_form_sheet.dart';

/// A barcode that already belongs to another product must say so *on the
/// barcode field*, naming the product that owns it — before this the dialog
/// showed a single "could not save the variant" line (and, on the product
/// endpoints, a 500).
void main() {
  const conflictBody = {
    'barcode': ['Barcode "999" is already used by "قهوة عربية".'],
    'conflicts': [
      {
        'field': 'barcode',
        'value': '999',
        'kind': 'variant',
        'target': 'variant',
        'index': '',
        'product_id': '7',
        'product_name': 'قهوة عربية',
        'variant_id': '70',
        'variant_sku': 'COF-1',
        'variant_name': '',
        'unit_code': '',
        'is_archived': 'false',
        'message': 'Barcode "999" is already used by "قهوة عربية".',
      },
    ],
  };

  const freeIdentity = {'sku': null, 'barcode': null};

  const takenIdentity = {
    'sku': null,
    'barcode': {
      'field': 'barcode',
      'value': '999',
      'kind': 'variant',
      'target': '',
      'index': null,
      'product_id': 7,
      'product_name': 'قهوة عربية',
      'variant_id': 70,
      'variant_sku': 'COF-1',
      'variant_name': '',
      'unit_code': '',
      'is_archived': false,
      'message': 'Barcode "999" is already used by "قهوة عربية".',
    },
  };

  Product buildProduct() => const Product(
    id: 1,
    name: 'شاي',
    quantityOnHand: 0,
    variants: [
      ProductVariant(id: 11, productId: 1, sku: 'TEA-1', unitPrice: 5),
    ],
  );

  /// Serves the identity probe and the variant create, and records what the
  /// dialog asked about.
  ({PosApiService service, List<Uri> identityCalls}) buildService({
    required Map<String, Object?> identityResponse,
    required int createStatus,
    Map<String, Object?> createBody = const {},
  }) {
    final identityCalls = <Uri>[];
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/identity-check/')) {
          identityCalls.add(request.url);
          return http.Response(
            jsonEncode(identityResponse),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode(createBody),
            createStatus,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(const {'results': <Object?>[], 'next': null}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    return (service: service, identityCalls: identityCalls);
  }

  Future<List<Uri>> pumpSheet(
    WidgetTester tester, {
    required Map<String, Object?> identityResponse,
    int createStatus = 201,
    Map<String, Object?> createBody = const {},
  }) async {
    final built = buildService(
      identityResponse: identityResponse,
      createStatus: createStatus,
      createBody: createBody,
    );
    final viewModel = ProductDetailsViewModel(
      _StubCatalogRepository(built.service, buildProduct()),
      _StubPurchaseRepository(built.service),
      _StubSaleRepository(built.service),
      buildProduct(),
      shouldLoadSaleHistory: false,
      shouldLoadPurchaseHistory: false,
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ProductVariantFormSheet(viewModel: viewModel)),
      ),
    );
    await tester.pumpAndSettle();
    return built.identityCalls;
  }

  testWidgets('a barcode owned by another product is flagged while typing', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final identityCalls = await pumpSheet(
      tester,
      identityResponse: takenIdentity,
    );

    await tester.enterText(find.byType(TextFormField).at(2), '999');
    // Past the debounce, then the lookup itself.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(identityCalls, isNotEmpty);
    expect(identityCalls.last.queryParameters['barcode'], '999');
    expect(find.text(l10n.barcodeTakenError('قهوة عربية')), findsOneWidget);
  });

  testWidgets('a free barcode reads as available', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await pumpSheet(tester, identityResponse: freeIdentity);

    await tester.enterText(find.byType(TextFormField).at(2), '123');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text(l10n.barcodeAvailableLabel), findsOneWidget);
  });

  testWidgets('a rejected save marks the field the server named', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    // The probe says the code is free — the clash only appears at save time,
    // which is exactly the race the server response has to cover.
    await pumpSheet(
      tester,
      identityResponse: freeIdentity,
      createStatus: 400,
      createBody: conflictBody,
    );

    await tester.enterText(find.byType(TextFormField).at(1), 'NEW-1');
    await tester.enterText(find.byType(TextFormField).at(2), '999');
    await tester.enterText(find.byType(TextFormField).at(3), '5');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.tap(find.text(l10n.createVariantButton));
    await tester.pumpAndSettle();

    expect(find.text(l10n.barcodeTakenError('قهوة عربية')), findsOneWidget);
    // The footer points at the marked field instead of repeating a generic
    // "could not create the variant".
    expect(find.text(l10n.formFixHighlightedFieldsError), findsOneWidget);
    expect(find.text(l10n.variantCreateError), findsNothing);
  });

  testWidgets('dismissing with unsaved edits asks before discarding', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final built = buildService(
      identityResponse: freeIdentity,
      createStatus: 201,
    );
    final viewModel = ProductDetailsViewModel(
      _StubCatalogRepository(built.service, buildProduct()),
      _StubPurchaseRepository(built.service),
      _StubSaleRepository(built.service),
      buildProduct(),
      shouldLoadSaleHistory: false,
      shouldLoadPurchaseHistory: false,
    );
    addTearDown(viewModel.dispose);

    // The sheet has to sit on a route of its own for a back attempt to reach
    // its PopScope, the way showAdaptiveFormSurface presents it.
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              Scaffold(body: ProductVariantFormSheet(viewModel: viewModel)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(1), 'NEW-1');
    await tester.pumpAndSettle();

    navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();

    expect(find.text(l10n.unsavedChangesTitle), findsOneWidget);
  });

  testWidgets('editing the flagged barcode clears its error', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await pumpSheet(tester, identityResponse: takenIdentity);

    await tester.enterText(find.byType(TextFormField).at(2), '999');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text(l10n.barcodeTakenError('قهوة عربية')), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(2), '9990');
    await tester.pump();

    expect(find.text(l10n.barcodeTakenError('قهوة عربية')), findsNothing);
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
