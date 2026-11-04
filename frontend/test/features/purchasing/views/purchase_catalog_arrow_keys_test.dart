import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_catalog_pane.dart';
import 'package:pointy_frontend/src/shared/barcode/barcode_scan_listener.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// Picking a product from the keyboard: ↓ from the search box into the
/// results, arrows between them, Enter adds — all real key events, under the
/// same scan listener the purchasing screen wraps the catalog in.
void main() {
  final variants = [
    for (var id = 1; id <= 6; id++)
      ProductVariant(
        id: id,
        productId: id,
        sku: 'SKU-$id',
        productName: 'صنف $id',
        unitPrice: 5,
      ),
  ];

  Future<PurchaseViewModel> pumpPane(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewModel = PurchaseViewModel(
      _FakeCatalogRepository(variants),
      _FakePurchaseRepository(),
    );
    addTearDown(viewModel.dispose);
    await viewModel.loadCatalog();
    final capabilities = AuthorizationCapabilities.forUser(
      PosUser.fromJson({
        'id': 1,
        'username': 'manager',
        'display_name': 'manager',
        'email': '',
        'role': 'manager',
        'permissions': <String>[],
        'is_active': true,
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Scaffold(
          body: BarcodeScanListener(
            onBarcodeScanned: (_) {},
            // As on the screen: arrows cycle the active line's unit — which
            // must not swallow them while the results have focus.
            onArrowKey: (_) => true,
            child: ListenableBuilder(
              listenable: viewModel,
              builder: (context, _) => PurchaseCatalogPane(
                viewModel: viewModel,
                capabilities: capabilities,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return viewModel;
  }

  String? focusedTileSku() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return null;
    String? sku;
    context.visitAncestorElements((element) {
      final key = element.widget.key;
      if (key is ValueKey<int>) {
        sku = 'SKU-${key.value}';
        return false;
      }
      return true;
    });
    return sku;
  }

  bool searchFocused() =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  Iterable<DecoratedBox> focusRings(WidgetTester tester) => tester
      .widgetList<DecoratedBox>(find.byType(DecoratedBox))
      .where(
        (box) =>
            box.position == DecorationPosition.foreground &&
            (box.decoration as BoxDecoration?)?.border != null,
      );

  testWidgets('down from the search box selects the FIRST result, visibly', (
    tester,
  ) async {
    await pumpPane(tester);
    expect(searchFocused(), isTrue);
    expect(focusRings(tester), isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(focusedTileSku(), 'SKU-1');
    // Drawn over the image, so the selection can actually be seen.
    expect(focusRings(tester), hasLength(1));
  });

  testWidgets('arrows move between results, not the active line unit', (
    tester,
  ) async {
    await pumpPane(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    // Right-to-left: the next card in reading order is to the LEFT.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(focusedTileSku(), 'SKU-2');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focusedTileSku(), isNot(anyOf('SKU-1', 'SKU-2')));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(focusedTileSku(), 'SKU-2');
    expect(focusRings(tester), hasLength(1));
  });

  testWidgets('Esc from a result goes back to the search box', (tester) async {
    await pumpPane(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focusedTileSku(), isNotNull);

    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    debugPrint('esc handled=$handled focus=${FocusManager.instance.primaryFocus}');

    expect(searchFocused(), isTrue);
  });

  testWidgets('Enter on a result adds it', (tester) async {
    final viewModel = await pumpPane(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final sku = focusedTileSku();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(viewModel.draft.single.variant.sku, sku);
  });
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository(this.variants) : super(PosApiService());

  final List<ProductVariant> variants;

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => Ok(ProductVariantPage(variants: variants, hasMore: false));

  @override
  Future<Result<Product>> loadProduct(int id) async =>
      Error(Exception('product $id not found'));
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());

  @override
  Future<Result<double?>> loadLastProductCost(
    int productId, {
    int? variantId,
  }) async => const Ok(2);
}
