import 'package:flutter/gestures.dart';
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
import 'package:pointy_frontend/src/data/models/voucher_menu.dart';
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
import 'package:pointy_frontend/src/features/pos/views/pos_screen.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_voucher_brand_card.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_voucher_brand_sheet.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import '../../../support/voucher_menu_testing.dart';

/// The «كروت دفتر» chip opens the company's own menu in the grid's place. A
/// brand opens its sheet; the card picked there is an ordinary invoice line
/// whose name says the brand, the country and the denomination.
void main() {
  late _FakeIntegrationsRepository integrations;

  setUp(() {
    integrations = _FakeIntegrationsRepository();
  });

  testWidgets('the chip opens the menu, and a search filters it in place', (
    tester,
  ) async {
    _useWideTill(tester);
    final viewModel = await _activeSessionViewModel(integrations);
    addTearDown(viewModel.dispose);
    await _pumpPos(tester, viewModel, integrations);

    expect(find.byType(PointyProductCard), findsNWidgets(2));
    expect(find.byType(PosVoucherBrandCard), findsNothing);

    await tester.tap(find.text('كروت دفتر'));
    await tester.pumpAndSettle();

    expect(viewModel.showsVoucherMenu, isTrue);
    expect(find.byType(PosVoucherBrandCard), findsNWidgets(3));
    expect(find.byType(PointyProductCard), findsNothing);
    expect(find.text('آيتونز'), findsOneWidget);

    await viewModel.updateSearch('آيتونز');
    await tester.pumpAndSettle();
    expect(viewModel.showsVoucherMenu, isTrue, reason: 'typing stays here');
    expect(find.byType(PosVoucherBrandCard), findsOneWidget);
    expect(find.byType(PointyProductCard), findsNothing);

    await viewModel.updateSearch('قهوة');
    await tester.pumpAndSettle();
    expect(find.byType(PosVoucherBrandCard), findsNothing);
    expect(find.byKey(const ValueKey('voucher_search_empty')), findsOneWidget);

    await viewModel.updateSearch('');
    await tester.pumpAndSettle();
    expect(find.byType(PosVoucherBrandCard), findsNWidgets(3));
  });

  testWidgets('the company\'s tabs narrow the brands to a category', (
    tester,
  ) async {
    _useWideTill(tester);
    final viewModel = await _activeSessionViewModel(integrations);
    addTearDown(viewModel.dispose);
    await _pumpPos(tester, viewModel, integrations);
    await tester.tap(find.text('كروت دفتر'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('voucher_category_games')));
    await tester.pumpAndSettle();
    expect(find.byType(PosVoucherBrandCard), findsOneWidget);
    expect(find.byKey(const ValueKey('voucher_brand_playstation')), findsOne);

    await tester.tap(find.byKey(const ValueKey('voucher_category_all')));
    await tester.pumpAndSettle();
    expect(find.byType(PosVoucherBrandCard), findsNWidgets(3));
  });

  testWidgets('tabs that outgrow the row scroll with a wheel and a mouse', (
    tester,
  ) async {
    _useWideTill(tester);
    integrations.extraTabs = 9;
    final viewModel = await _activeSessionViewModel(integrations);
    addTearDown(viewModel.dispose);
    await _pumpPos(tester, viewModel, integrations);
    await tester.tap(find.text('كروت دفتر'));
    await tester.pumpAndSettle();

    // Taken once: the first tab leaves the tree when the row scrolls on.
    final rowFinder = find
        .ancestor(
          of: find.byKey(const ValueKey('voucher_category_all')),
          matching: find.byWidgetPredicate(
            (widget) => widget is Scrollable && widget.axis == Axis.horizontal,
          ),
        )
        .first;
    final position = tester.state<ScrollableState>(rowFinder).position;
    final middle = tester.getCenter(rowFinder);
    expect(position.maxScrollExtent, greaterThan(200));
    expect(position.pixels, 0);

    // The wheel has no sideways axis of its own: its turns move the row.
    final wheel = TestPointer(1, PointerDeviceKind.mouse);
    wheel.hover(middle);
    await tester.sendEventToBinding(wheel.scroll(const Offset(0, 120)));
    await tester.pump();
    expect(position.pixels, 120);

    // And a dragged mouse, which a list ignores unless told otherwise.
    await tester.dragFrom(
      middle,
      const Offset(50, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(position.pixels, isNot(120));
  });

  testWidgets(
    'a card picked for another country lands as a line naming all of it',
    (tester) async {
      _useWideTill(tester);
      final viewModel = await _activeSessionViewModel(integrations);
      addTearDown(viewModel.dispose);
      await _pumpPos(tester, viewModel, integrations);
      await tester.tap(find.text('كروت دفتر'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('voucher_brand_itunes')));
      await tester.pumpAndSettle();
      // The sheet opens on the first country the company listed.
      expect(find.byType(PosVoucherBrandPicker), findsOneWidget);
      expect(find.byKey(const ValueKey('voucher_item_card-9101')), findsOne);
      expect(
        find.byKey(const ValueKey('voucher_item_card-9105')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('voucher_country_GB')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('voucher_item_card-9101')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('voucher_item_card-9105')), findsOne);

      await tester.tap(find.byKey(const ValueKey('voucher_item_card-9105')));
      await tester.pumpAndSettle();

      expect(find.byType(PosVoucherBrandPicker), findsNothing);
      final line = viewModel.cart.single;
      expect(line.isVoucher, isTrue);
      expect(line.variant.id, 9105);
      expect(line.variant.displayLabel, 'آيتونز - المملكة المتحدة · 10 جنيه');
      expect(line.subtotal, 75);
    },
  );

  testWidgets('a sold-out card is shown but cannot be picked', (tester) async {
    _useWideTill(tester);
    final viewModel = await _activeSessionViewModel(integrations);
    addTearDown(viewModel.dispose);
    await _pumpPos(tester, viewModel, integrations);
    await tester.tap(find.text('كروت دفتر'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voucher_brand_itunes')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('voucher_item_card-9104')));
    await tester.pumpAndSettle();

    expect(viewModel.cart, isEmpty);
    expect(find.byType(PosVoucherBrandPicker), findsOneWidget);
  });

  testWidgets('a failed read keeps the grid under its error, and retries', (
    tester,
  ) async {
    _useWideTill(tester);
    integrations.fail = true;
    final viewModel = await _activeSessionViewModel(integrations);
    addTearDown(viewModel.dispose);
    await _pumpPos(tester, viewModel, integrations);
    await tester.tap(find.text('كروت دفتر'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('voucher_menu_error')), findsOneWidget);
    // Never a blank till: the cards are products, still sellable from here.
    expect(find.byType(PointyProductCard), findsNWidgets(2));

    integrations.fail = false;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voucher_menu_error')), findsNothing);
    expect(find.byType(PosVoucherBrandCard), findsNWidgets(3));
  });

  testWidgets('picking the chip again re-reads what is held', (tester) async {
    _useWideTill(tester);
    final viewModel = await _activeSessionViewModel(integrations);
    addTearDown(viewModel.dispose);
    await _pumpPos(tester, viewModel, integrations);

    await tester.tap(find.text('كروت دفتر'));
    await tester.pumpAndSettle();
    expect(integrations.menuReads, 1);

    await tester.tap(find.text('كروت دفتر'));
    await tester.pumpAndSettle();
    expect(integrations.menuReads, 2);
    // Held, not blanked, while it re-reads.
    expect(find.byType(PosVoucherBrandCard), findsNWidgets(3));
  });

  group('a brand\'s sheet', () {
    Future<List<ProductVariant>> pumpPicker(
      WidgetTester tester, {
      required bool withCost,
      bool costRevealed = true,
    }) async {
      final picked = <ProductVariant>[];
      final menu = VoucherMenu.fromJson(voucherMenuJson(withCost: withCost));
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: PosVoucherBrandPicker(
              brand: menu.brands.first,
              countryFor: menu.country,
              balance: menu.balance,
              showsProfit: costRevealed,
              onPicked: picked.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return picked;
    }

    testWidgets('shows what a card earns only to a reader sent its cost', (
      tester,
    ) async {
      _useWideTill(tester);
      await pumpPicker(tester, withCost: true);
      expect(find.textContaining('ربحك'), findsWidgets);
      expect(find.textContaining('17.00'), findsOneWidget);

      await pumpPicker(tester, withCost: false);
      expect(find.textContaining('ربحك'), findsNothing);
    });

    testWidgets('keeps the profit hidden until cost is revealed (F9)', (
      tester,
    ) async {
      _useWideTill(tester);
      // The screen faces customers too: an owner sees the margin only after
      // revealing cost, as with the cart's own margin line.
      await pumpPicker(tester, withCost: true, costRevealed: false);
      expect(find.textContaining('ربحك'), findsNothing);
    });

    testWidgets('flags a card dearer than the balance, and still sells it', (
      tester,
    ) async {
      _useWideTill(tester);
      final picked = await pumpPicker(tester, withCost: false);

      expect(find.text('يتجاوز رصيد الكروت'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('voucher_item_card-9103')));
      expect(picked.single.id, 9103);
    });

    testWidgets('marks a promotion with its badge and the price it beats', (
      tester,
    ) async {
      _useWideTill(tester);
      await pumpPicker(tester, withCost: false);

      final promo = find.byKey(const ValueKey('voucher_item_card-9102'));
      expect(
        find.descendant(of: promo, matching: find.text('عرض')),
        findsOneWidget,
      );
      final struck = tester.widget<Text>(
        find.descendant(of: promo, matching: find.textContaining('150.00')),
      );
      expect(struck.style?.decoration, TextDecoration.lineThrough);
      expect(find.text('رصيد الكروت: 345.50 د.ل'), findsOneWidget);
    });
  });
}

class _FakeIntegrationsRepository extends IntegrationsRepository {
  _FakeIntegrationsRepository() : super(PosApiService());

  bool fail = false;
  int menuReads = 0;

  /// Categories beyond the fixture's three, each holding a copy of its first
  /// brand: a shelf with more tabs than a till's pane is wide.
  int extraTabs = 0;

  @override
  Future<Result<VoucherMenu>> loadVoucherMenu() async {
    menuReads++;
    if (fail) {
      return Error(Exception('offline'));
    }
    final json = voucherMenuJson(
      withCost: false,
      extraCategories: [
        for (var i = 1; i <= extraTabs; i++)
          {'key': 'extra$i', 'name': 'تصنيف رقم $i'},
      ],
    );
    final brands = (json['brands']! as List).cast<Map<String, Object?>>();
    json['brands'] = [
      ...brands,
      for (var i = 1; i <= extraTabs; i++)
        {...brands.first, 'key': 'copy$i', 'category': 'extra$i'},
    ];
    return Ok(VoucherMenu.fromJson(json));
  }
}

Widget _app(Widget home) {
  return MaterialApp(
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
    home: home,
  );
}

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

const _vouchersChip = ProductCategory(
  id: 99,
  name: 'كروت دفتر',
  isQuickAccess: true,
  isSystem: true,
  systemKey: ProductCategorySystemKey.pointyVouchers,
);

const _coffee = Product(
  id: 42,
  name: 'قهوة عربية',
  quantityOnHand: 30,
  defaultVariant: ProductVariant(
    id: 420,
    productId: 42,
    sku: 'COF-100',
    unitPrice: 5.50,
    quantityOnHand: 30,
  ),
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
      const Ok([
        ProductCategory(id: 1, name: 'مشروبات', isQuickAccess: true),
        _vouchersChip,
      ]);
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

  @override
  Future<Result<SaleDiscountPreview>> previewDiscounts(
    SaleDiscountPreviewDraft draft,
  ) async =>
      const Ok(SaleDiscountPreview(subtotal: 0, discountTotal: 0, total: 0));
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

Future<PosViewModel> _activeSessionViewModel(
  IntegrationsRepository integrations,
) async {
  final viewModel = PosViewModel(
    _FakeCatalogRepository(),
    _FakeRegisterSessionRepository(),
    _FakeSaleRepository(),
    ShopSettingsRepository(PosApiService()),
    PrintingRepository(PosApiService()),
    integrationsRepository: integrations,
    sessionStorage: MemoryScopedJsonStorage(),
  );
  await viewModel.loadCurrentRegisterSession();
  await viewModel.resumeRegisterSession();
  return viewModel;
}

Future<void> _pumpPos(
  WidgetTester tester,
  PosViewModel viewModel,
  IntegrationsRepository integrations,
) async {
  await tester.pumpWidget(
    _app(
      PosScreen(
        viewModel: viewModel,
        contactRepository: ContactRepository(PosApiService()),
        printingRepository: PrintingRepository(PosApiService()),
        shopSettingsRepository: ShopSettingsRepository(PosApiService()),
        catalogRepository: _FakeCatalogRepository(),
        purchaseRepository: PurchaseRepository(PosApiService()),
        integrationsRepository: integrations,
        capabilities: _managerCaps,
        navigation: _FakeNavigation(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
