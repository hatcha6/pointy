import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_screen.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

final PosUser _managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
});

final AuthorizationCapabilities _managerCaps =
    AuthorizationCapabilities.forUser(_managerUser);

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());

  @override
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
    bool bypassCache = false,
  }) async => const Ok(ProductPage(products: [], hasMore: false));

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => const Ok(ProductVariantPage(variants: [], hasMore: false));

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

void main() {
  testWidgets(
    'app bar shows one labeled session control instead of cryptic icons',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final viewModel = await _activeSessionViewModel();
      addTearDown(viewModel.dispose);
      expect(viewModel.activeRegisterSession, isNotNull);

      await _pumpPos(tester, viewModel);

      // The toolbar is a single labeled pill that names the session and signals a
      // menu — none of the old standalone icon-only buttons remain in the bar.
      final appBar = find.byType(AppBar);
      expect(
        find.descendant(of: appBar, matching: find.text('جلسة RS-2')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: appBar,
          matching: find.byIcon(Icons.expand_more_rounded),
        ),
        findsOneWidget,
      );
      for (final cryptic in const [
        Icons.lock_outline,
        Icons.account_balance_wallet_outlined,
        Icons.sync,
        Icons.request_quote_outlined,
      ]) {
        expect(
          find.descendant(of: appBar, matching: find.byIcon(cryptic)),
          findsNothing,
          reason:
              'cryptic toolbar icon $cryptic should be gone from the app bar',
        );
      }
    },
  );

  testWidgets('the session pill opens a menu where every action reads clearly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final viewModel = await _activeSessionViewModel();
    addTearDown(viewModel.dispose);

    await _pumpPos(tester, viewModel);

    await tester.tap(find.text('جلسة RS-2'));
    await tester.pumpAndSettle();

    // Every register action is now a labeled tile with a plain-language subtitle.
    expect(find.text('إجراءات الجلسة'), findsOneWidget);
    expect(find.text('إضافة نقدية'), findsOneWidget);
    expect(find.text('إيداع مبلغ نقدي في الدرج'), findsOneWidget);
    expect(find.text('سحب نقدية'), findsOneWidget);
    // The drawer-paid quick purchase (manager holds every capability).
    expect(find.text('شراء نقدي من الصندوق'), findsOneWidget);
    expect(find.text('تحصيل دين'), findsOneWidget);
    expect(find.text('تحديث المنتجات'), findsOneWidget);
    expect(find.text('إغلاق جلسة الدرج'), findsOneWidget);
    // The close action's icon now lives inside its labeled tile.
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);

    // Choosing an action dismisses the menu (here: refresh products).
    await tester.tap(find.text('تحديث المنتجات'));
    await tester.pumpAndSettle();
    expect(find.text('إجراءات الجلسة'), findsNothing);
  });
}
