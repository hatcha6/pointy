import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_catalog_pane.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_screen.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import '../../../support/key_value_store_testing.dart';

/// The till's catalog can be read as picture cards or as a table. Either way
/// it is the same catalog: a row sells exactly what its card would.
void main() {
  testWidgets('the till switches its catalog to a table and remembers it', (
    tester,
  ) async {
    _useWideTill(tester);
    final store = installMemoryKeyValueStore();
    final viewModel = await _activeSessionViewModel();
    addTearDown(viewModel.dispose);

    await _pumpPos(tester, viewModel);

    // Cards until somebody asks for something else.
    expect(find.byType(PointyProductCard), findsNWidgets(2));
    expect(find.byType(PointyCatalogRow), findsNothing);

    await tester.tap(
      _inCatalog(find.byKey(const ValueKey('catalog_layout_list'))),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PointyProductCard), findsNothing);
    expect(find.byType(PointyCatalogRow), findsNWidgets(2));
    expect(_inCatalog(find.text('المخزون')), findsOneWidget);
    expect(await store.getString('pos_catalog_layout'), 'list');

    await tester.tap(
      _inCatalog(find.byKey(const ValueKey('catalog_layout_grid'))),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PointyProductCard), findsNWidgets(2));
    expect(find.byType(PointyCatalogRow), findsNothing);
    expect(await store.getString('pos_catalog_layout'), 'grid');
  });

  testWidgets('a till that chose the table opens on it and sells from a row', (
    tester,
  ) async {
    _useWideTill(tester);
    installMemoryKeyValueStore({'pos_catalog_layout': 'list'});
    final viewModel = await _activeSessionViewModel();
    addTearDown(viewModel.dispose);

    await _pumpPos(tester, viewModel);

    expect(find.byType(PointyCatalogRow), findsNWidgets(2));
    expect(find.byType(PointyProductCard), findsNothing);

    final coffeeRow = find.widgetWithText(PointyCatalogRow, 'قهوة عربية');
    await tester.tap(coffeeRow);
    await tester.pumpAndSettle();

    expect(viewModel.cart, hasLength(1));
    expect(viewModel.cart.single.variant.id, _coffee.defaultVariant!.id);
    // The row now says it is in the sale, the way the card's badge does.
    expect(
      find.descendant(
        of: coffeeRow,
        matching: find.byType(PointyCartQuantityBadge),
      ),
      findsOneWidget,
    );
  });
}

Finder _inCatalog(Finder finder) =>
    find.descendant(of: find.byType(PosCatalogPane), matching: finder);

void _useWideTill(WidgetTester tester) {
  tester.view.physicalSize = const Size(1440, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

final PosUser _managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
});

final AuthorizationCapabilities _managerCaps =
    AuthorizationCapabilities.forUser(_managerUser);

const _coffee = Product(
  id: 42,
  name: 'قهوة عربية',
  quantityOnHand: 30,
  defaultVariant: ProductVariant(
    id: 420,
    productId: 42,
    sku: 'COF-100',
    barcode: '6281100001234',
    unitPrice: 5.50,
    quantityOnHand: 30,
  ),
  variants: [
    ProductVariant(
      id: 420,
      productId: 42,
      sku: 'COF-100',
      barcode: '6281100001234',
      unitPrice: 5.50,
      quantityOnHand: 30,
    ),
  ],
);

const _tea = Product(
  id: 43,
  name: 'شاي أخضر',
  quantityOnHand: 4,
  defaultVariant: ProductVariant(
    id: 430,
    productId: 43,
    sku: 'TEA-200',
    unitPrice: 3.25,
    quantityOnHand: 4,
  ),
  variants: [
    ProductVariant(
      id: 430,
      productId: 43,
      sku: 'TEA-200',
      unitPrice: 3.25,
      quantityOnHand: 4,
    ),
  ],
);

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());

  @override
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
    bool bypassCache = false,
  }) async => Ok(
    ProductPage(
      products: page == 1 ? const [_coffee, _tea] : const [],
      hasMore: false,
    ),
  );

  @override
  Future<Result<List<ProductCategory>>> loadQuickAccessCategories() async =>
      const Ok([]);
}

class _FakeRegisterSessionRepository extends RegisterSessionRepository {
  _FakeRegisterSessionRepository() : super(PosApiService());

  @override
  Future<Result<RegisterSession?>> loadCurrentSession() async => const Ok(
    RegisterSession(
      id: 2,
      sessionNumber: 'RS-2',
      status: 'open',
      openingCash: 100,
    ),
  );
}

class _FakeSaleRepository extends SaleRepository {
  _FakeSaleRepository() : super(PosApiService());

  // Adding a line refreshes the totals; answer locally so no request leaves
  // the test. The figures are not what this file is about.
  @override
  Future<Result<SaleDiscountPreview>> previewDiscounts(
    SaleDiscountPreviewDraft draft,
  ) async =>
      const Ok(SaleDiscountPreview(subtotal: 0, discountTotal: 0, total: 0));
}

class _FakeShopSettingsRepository extends ShopSettingsRepository {
  _FakeShopSettingsRepository() : super(PosApiService());
}

class _FakeContactRepository extends ContactRepository {
  _FakeContactRepository() : super(PosApiService());
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());
}

class _FakeNavigation implements AppNavigation {
  @override
  PosUser get currentUser => _managerUser;

  @override
  AuthorizationCapabilities get capabilities => _managerCaps;

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}

Future<PosViewModel> _activeSessionViewModel() async {
  final viewModel = PosViewModel(
    _FakeCatalogRepository(),
    _FakeRegisterSessionRepository(),
    _FakeSaleRepository(),
    _FakeShopSettingsRepository(),
    PrintingRepository(PosApiService()),
    sessionStorage: MemoryScopedJsonStorage(),
  );
  await viewModel.loadCurrentRegisterSession();
  await viewModel.resumeRegisterSession();
  return viewModel;
}

Future<void> _pumpPos(WidgetTester tester, PosViewModel viewModel) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: PosScreen(
        viewModel: viewModel,
        contactRepository: _FakeContactRepository(),
        printingRepository: PrintingRepository(PosApiService()),
        shopSettingsRepository: _FakeShopSettingsRepository(),
        catalogRepository: _FakeCatalogRepository(),
        purchaseRepository: _FakePurchaseRepository(),
        integrationsRepository: IntegrationsRepository(PosApiService()),
        capabilities: _managerCaps,
        navigation: _FakeNavigation(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
